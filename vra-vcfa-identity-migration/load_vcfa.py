"""Load vcfa-import.json into VCF Automation (VCFA) via the cloudapi. DRY RUN unless you choose Apply.

    python load_vcfa.py                 # interactive: prompts for host, org, login method, action, filters
    python load_vcfa.py --org my-org --browser-token                    # dry run, groups only (the default)
    python load_vcfa.py --org my-org --browser-token --users            # groups and users
    python load_vcfa.py --org my-org --browser-token --only "My-Group@corp.example.com" --apply   # one group
    python load_vcfa.py --org my-org --browser-token --only "olga@corp.example.com" --apply       # one user

Groups only unless you ask for users (--users, or name a user in --only). Project roles are never loaded.
With no flags you get an action menu: test login / dry run / apply. With any flag the action is a dry run
unless --apply (or --login-only) is given. When stdin is not a terminal nothing is prompted.
Reads vcfa-import.json from the current folder. Writes vcfa-plan.json (the exact requests) in dry-run.
Defaults come from the env vars VCFA_HOST, VCFA_ORG, VCFA_USERNAME, VCFA_PASSWORD, VCFA_API_TOKEN,
VCFA_BROWSER_TOKEN or the constants below.
"""
import argparse
import base64
import getpass
import json
import os
import re
import sys
from datetime import datetime, timezone

import requests

# Every value below is asked for in the terminal; what you set here (or in an env var) is only the default.
VCFA_HOST = os.environ.get("VCFA_HOST", "https://vcfa.example.com")  # e.g. "dev.vcfa.local" (https:// is added if missing; env VCFA_HOST)
ORG = os.environ.get("VCFA_ORG", "my-org")   # tenant/org name, e.g. "finance-org" (env VCFA_ORG)
VERIFY_TLS = False     # asked at the prompt; False accepts a self-signed certificate (lab). e.g. True for a CA-signed cert
TIMEOUT = 30           # seconds per request (not asked); e.g. 120 for a slow appliance
API_VERSION = os.environ.get("VCFA_API_VERSION", "40.0")  # cloudapi version (not asked); e.g. "40.0" (env VCFA_API_VERSION)
IMPORT_FILE = "vcfa-import.json"  # asked at the prompt (or --import-file); e.g. "example-vcfa-import.json"
PLAN_FILE = "vcfa-plan.json"
REPORT_FILE = "vcfa-load-report.html"  # the readable summary of the run is written here      # dry-run/apply plan is written here
VCFA_API_TOKEN = ""  # for OIDC/SSO orgs: API token created in the VCFA UI (env VCFA_API_TOKEN); prompted if you pick that login method
VCFA_BROWSER_TOKEN = ""  # browser session token, raw or a 'Copy as fetch' capture (env VCFA_BROWSER_TOKEN); prompted for the browser method
VCFA_USERNAME = ""          # e.g. "configurationadmin" (env VCFA_USERNAME)
VCFA_PASSWORD = ""          # leave empty to be prompted; never commit it (env VCFA_PASSWORD)
if not VERIFY_TLS:
    requests.packages.urllib3.disable_warnings()  # type: ignore[attr-defined]
s = requests.Session()
s.verify = VERIFY_TLS


def die(msg):
    sys.exit(f"ERROR: {msg}")


def ask(label, default="", secret=False, example=""):
    """Prompt with a default (Enter accepts it) or an example when there is no default.
    Returns the default when stdin is not a terminal."""
    if not sys.stdin.isatty():
        return default
    if secret:
        return getpass.getpass(f"{label}: ") or default
    hint = f" [{default}]" if default else (f" (e.g. {example})" if example else "")
    return input(f"{label}{hint}: ").strip() or default


def confirm(label, default=False):
    """Yes/no prompt. Returns the default when stdin is not a terminal."""
    if not sys.stdin.isatty():
        return default
    while True:
        raw = input(f"{label} [{'Y/n' if default else 'y/N'}]: ").strip().lower()
        if not raw:
            return default
        if raw in ("y", "yes", "n", "no"):
            return raw.startswith("y")
        print("  Answer y or n.")


def normalize_host(value):
    """Turn what the user typed into a clean base URL, e.g. 'dev.vra.local' -> 'https://dev.vra.local'.
    No scheme means https. An explicit http:// or https:// is kept. Path, query and trailing slashes are dropped,
    the host is lower-cased and a port is kept (e.g. 'vra.local:8443'). Raises ValueError if it is not a host."""
    from urllib.parse import urlsplit
    v = (value or "").strip()
    if not v:
        raise ValueError("enter a host name, e.g. dev.vra.local")
    if " " in v:
        raise ValueError(f"'{v}' contains a space")
    if "://" not in v:
        v = "https://" + v
    u = urlsplit(v)
    if u.scheme.lower() not in ("http", "https"):
        raise ValueError(f"only http:// or https:// is supported, not '{u.scheme}://'")
    if u.username or u.password:
        raise ValueError("do not put a user name or password in the host")
    try:
        host, port = u.hostname, u.port
    except ValueError:
        raise ValueError(f"'{value.strip()}' has an invalid port")
    if not host:
        raise ValueError(f"'{value.strip()}' is not a valid host name")
    return f"{u.scheme.lower()}://{host}" + (f":{port}" if port else "")


def ask_host(label, default="", example=""):
    """Prompt for a host and return it as a clean base URL; asks again on invalid input."""
    while True:
        raw = ask(label, default, example=example)
        try:
            return normalize_host(raw)
        except ValueError as e:
            if not sys.stdin.isatty():
                die(f"{label}: {e}")
            print(f"  {e}")


def choose(label, options, default=1):
    """Numbered menu; options is a list of (value, description). Returns the chosen value."""
    if not sys.stdin.isatty():
        return options[default - 1][0]
    print(label)
    for i, (_, desc) in enumerate(options, 1):
        print(f"  {i}) {desc}")
    while True:
        raw = input(f"Choice [{default}]: ").strip() or str(default)
        if raw.isdigit() and 1 <= int(raw) <= len(options):
            return options[int(raw) - 1][0]
        print("  Enter one of the numbers above.")


def credentials():
    user = ask("VCFA username", os.environ.get("VCFA_USERNAME") or VCFA_USERNAME, example="configurationadmin")
    pw = os.environ.get("VCFA_PASSWORD") or VCFA_PASSWORD or ask("VCFA password", secret=True)
    if not (user and pw):
        die("username and password are required")
    return user, pw


def login(user, pw, org):
    """Tenant login (cloudapi sessions). Returns (headers, session_body)."""
    basic = base64.b64encode(f"{user}:{pw}".encode()).decode()  # username is used as given; org is not appended
    r = s.post(f"{VCFA_HOST}/cloudapi/1.0.0/sessions",
               headers={"Authorization": f"Basic {basic}", "Accept": f"application/json;version={API_VERSION}"},
               timeout=TIMEOUT)
    if r.status_code not in (200, 201):
        die(f"login failed ({r.status_code}): {r.text[:300]}")
    token = r.headers.get("X-VMWARE-VCLOUD-ACCESS-TOKEN")
    if not token:
        die("login returned no X-VMWARE-VCLOUD-ACCESS-TOKEN header")
    return {"Authorization": f"Bearer {token}", "Accept": f"application/json;version={API_VERSION}",
            "Content-Type": "application/json"}, r.json()


def token_login(api_token, org):
    """For OIDC/SSO orgs: exchange an API token (created in the UI) for an access token."""
    r = s.post(f"{VCFA_HOST}/oauth/tenant/{org}/token",
               data={"grant_type": "refresh_token", "refresh_token": api_token}, timeout=TIMEOUT)
    if r.status_code != 200:
        die(f"API token exchange failed ({r.status_code}): {r.text[:300]}")
    headers = {"Authorization": f"Bearer {r.json()['access_token']}",
               "Accept": f"application/json;version={API_VERSION}", "Content-Type": "application/json"}
    r = s.get(f"{VCFA_HOST}/cloudapi/1.0.0/sessions/current", headers=headers, timeout=TIMEOUT)
    if r.status_code != 200:
        die(f"could not read current session ({r.status_code}): {r.text[:300]}")
    return headers, r.json()


def bearer_login(path, org, text=None):
    """Use a browser session token. `path` holds a raw token or a 'Copy as fetch' capture (token is extracted, never printed).
    Pass `text` instead to use a token given as a variable."""
    import re
    if text is None:
        text = open(path, encoding="utf-8", errors="replace").read()
    # Raw token, 'Bearer <token>', a quoted token, or a copied request ('Copy as fetch', cURL or PowerShell).
    m = re.search(r"""authorization["']?\s*[:=]\s*["']?Bearer\s+([A-Za-z0-9._~+/=\-]+)""", text, re.I)
    token = m.group(1) if m else re.sub(r"(?i)^bearer\s+", "", text.strip().strip("\"'").strip()).strip()
    if not token or len(token) < 20:
        die(f"no bearer token found in {path or 'VCFA_BROWSER_TOKEN'}")
    if re.search(r"\s", token):
        die(f"the text from {path or 'VCFA_BROWSER_TOKEN'} has spaces or line breaks and no 'authorization: Bearer ...' "
            "header, so it is not a token. Copy only the token, or save the whole request to a file and use --bearer-file")
    headers = {"Authorization": f"Bearer {token}", "Accept": f"application/json;version={API_VERSION}",
               "Content-Type": "application/json"}
    r = s.get(f"{VCFA_HOST}/cloudapi/1.0.0/sessions/current", headers=headers, timeout=TIMEOUT)
    if r.status_code != 200:
        die(f"browser token rejected ({r.status_code}) - it probably expired; capture a fresh one: {r.text[:200]}")
    return headers, r.json()


def provider_login(api_token, org):
    """System-org (provider) API token: exchange at /oauth/provider/token, then act inside `org` via tenant context."""
    r = s.post(f"{VCFA_HOST}/oauth/provider/token",
               data={"grant_type": "refresh_token", "refresh_token": api_token}, timeout=TIMEOUT)
    if r.status_code != 200:
        die(f"provider API token exchange failed ({r.status_code}): {r.text[:300]}")
    headers = {"Authorization": f"Bearer {r.json()['access_token']}",
               "Accept": f"application/json;version={API_VERSION}", "Content-Type": "application/json"}
    r = s.get(f"{VCFA_HOST}/cloudapi/1.0.0/orgs", headers=headers, params={"filter": f"name=={org}"}, timeout=TIMEOUT)
    if r.status_code != 200 or not r.json().get("values"):
        die(f"could not find org '{org}' as provider ({r.status_code}): {r.text[:300]}")
    o = r.json()["values"][0]
    return headers, {"org": {"name": o["name"], "id": o["id"]}, "roles": ["(provider)"]}


def get_all(path, headers, page_size=128, max_pages=200):
    out = []
    for page in range(1, max_pages + 1):
        r = s.get(f"{VCFA_HOST}{path}", headers=headers, params={"page": page, "pageSize": page_size}, timeout=TIMEOUT)
        if r.status_code != 200:
            die(f"GET {path} failed ({r.status_code}): {r.text[:300]}")
        body = r.json()
        out.extend(body.get("values", []))
        if page >= body.get("pageCount", 1):
            break
    return out


def post(path, headers, body):
    r = s.post(f"{VCFA_HOST}{path}", headers=headers, data=json.dumps(body), timeout=TIMEOUT)
    return r.status_code, (r.json() if r.text else {})


def norm_role(name):
    """Compare role names ignoring case, spaces/punctuation and Admin/Administrator."""
    return "".join(c for c in name.lower().replace("administrator", "admin") if c.isalnum())


def direct_users(imp):
    """Users that need loading because some of their roles are NOT inherited from a group they are in.
    Returns {username (lower): [role names the groups do not give them]}. Users with no roles, and users whose roles
    are all provided by their groups, are left out: the IdP group claim covers them at their first login."""
    own, via_group, group_roles = {}, {}, {}
    for b in imp["roleBindings"]:
        if b["scope"] != "organization":
            continue
        if b["principalType"] == "group":
            group_roles.setdefault(b["principal"].lower(), {})[norm_role(b["role"])] = b["role"]
        else:
            own.setdefault(b["principal"].lower(), {})[norm_role(b["role"])] = b["role"]
    for g in imp["groups"]:
        for m in g.get("members", []):
            via_group.setdefault(m.lower(), set()).update(group_roles.get(g["name"].lower(), {}))
    out = {}
    for u in imp["users"]:
        k = u["username"].lower()
        extra = [name for key, name in sorted(own.get(k, {}).items()) if key not in via_group.get(k, set())]
        if extra:
            out[k] = extra
    return out


def build_plan(imp, roles, existing_users, existing_groups, org_ref):
    vcfa_roles = {norm_role(r["name"]): r for r in roles}  # tolerant match: "Assembler Admin" == "Assembler Administrator"
    have_users = {(u.get("username") or "").lower(): u for u in existing_users}
    have_groups = {(g.get("name") or "").lower(): g for g in existing_groups}

    org_roles = {}  # (type, principal) -> [vcfa role names]
    skipped_project = 0
    project_bindings = {}  # project scope -> [{type, principal, role}]; VCFA project membership is not loaded here
    for b in imp["roleBindings"]:
        if b["scope"] != "organization":
            skipped_project += 1
            project_bindings.setdefault(b["scope"], []).append(
                {"type": b["principalType"], "principal": b["principal"], "role": b["role"]})
            continue
        org_roles.setdefault((b["principalType"], b["principal"]), []).append(b["role"])

    missing_roles, creates, skipped, updates = {}, [], [], []
    missing_by = {}  # principal (lower) -> VCFA role names that do not exist in this org

    def sync(kind, name, key, existing):
        """Existing object: add the vRA roles it lacks (never removes roles it already has)."""
        have = {r["id"] for r in existing.get("roleEntityRefs") or []}
        add = [r for r in refs(kind, key) if r["id"] not in have]
        if add:
            body = dict(existing, roleEntityRefs=(existing.get("roleEntityRefs") or []) + add)
            updates.append({"type": kind, "name": name, "path": f"/cloudapi/1.0.0/{kind}s/{existing['id']}",
                            "adding": [r["name"] for r in add], "body": body})

    def refs(kind, key):
        out = []
        for name in sorted(set(org_roles.get((kind, key), []))):
            r = vcfa_roles.get(norm_role(name))
            if r:
                out.append({"name": r["name"], "id": r["id"]})  # always VCFA's own spelling
            else:
                missing_roles[name] = missing_roles.get(name, 0) + 1
                missing_by.setdefault(key.lower(), set()).add(name)
        return out

    for u in imp["users"]:
        key = u["username"]
        if u["username"].lower() in have_users:
            skipped.append({"type": "user", "name": u["username"], "reason": "already exists"})
            sync("user", u["username"], key, have_users[u["username"].lower()])
            continue
        if u["providerType"] == "LOCAL":
            skipped.append({"type": "user", "name": u["username"], "reason": "local user: needs a password, create manually"})
            continue
        # Same body the VCFA UI sends for "add user" (org comes from the tenant-context header).
        body = {"username": u["username"], "enabled": True, "providerType": u["providerType"],
                "roleEntityRefs": refs("user", key), "inheritGroupRoles": True}
        creates.append({"type": "user", "path": "/cloudapi/1.0.0/users", "body": body})

    for g in imp["groups"]:
        if g["name"].lower() in have_groups:
            skipped.append({"type": "group", "name": g["name"], "reason": "already exists"})
            sync("group", g["name"], g["name"], have_groups[g["name"].lower()])
            continue
        # Same body the VCFA UI sends for "add group" (org comes from the tenant-context header).
        body = {"name": g["name"], "providerType": g["providerType"],
                "roleEntityRefs": refs("group", g["name"]), "description": ""}
        creates.append({"type": "group", "path": "/cloudapi/1.0.0/groups", "body": body})

    mapping = {}  # role name in the import file -> VCFA role name it resolves to (None = not found)
    for b in imp["roleBindings"]:
        if b["scope"] == "organization":
            mapping[b["role"]] = (vcfa_roles.get(norm_role(b["role"])) or {}).get("name")
    local_with_roles = [{"name": u["username"], "roles": sorted(set(org_roles.get(("user", u["username"]), [])))}
                        for u in imp["users"] if u.get("providerType") == "LOCAL" and org_roles.get(("user", u["username"]))]
    return {"creates": creates, "updates": updates, "skipped": skipped, "missingRoles": missing_roles,
            "directUsers": direct_users(imp), "localUsersWithRoles": local_with_roles,
            "roleMapping": mapping,
            "missingByPrincipal": {k: sorted(v) for k, v in missing_by.items()},
            "projectBindingsNotHandled": skipped_project, "projectBindings": project_bindings}


def expected_roles(plan):
    """principal (lower) -> set of VCFA role names the plan sets (new objects: all; existing: the roles being added)."""
    out = {}
    for c in plan["creates"]:
        b = c["body"]
        out[(c["type"], (b.get("username") or b["name"]).lower())] = {r["name"].lower() for r in b["roleEntityRefs"]}
    for c in plan["updates"]:
        out[(c["type"], c["name"].lower())] = {r["name"].lower() for r in c["body"]["roleEntityRefs"]}
    return out


def blocked_by_missing_roles(plan):
    """Planned objects whose vRA roles do not all exist in VCFA, so they would end up with fewer roles."""
    wanted = {name for _, name in expected_roles(plan)}
    return {n: r for n, r in plan["missingByPrincipal"].items() if n in wanted}


def verify_roles(plan, headers):
    """Re-read VCFA after apply and compare each planned object's roles with what vRA had. Returns mismatches."""
    actual = {}
    for kind, path in (("user", "/cloudapi/1.0.0/users"), ("group", "/cloudapi/1.0.0/groups")):
        for o in get_all(path, headers):
            actual[(kind, (o.get("username") or o.get("name") or "").lower())] = {
                r["name"].lower() for r in o.get("roleEntityRefs") or []}
    bad = []
    for key, want in expected_roles(plan).items():
        have = actual.get(key)
        if have is None:
            bad.append({"type": key[0], "name": key[1], "problem": "not found in VCFA"})
        elif want - have:
            bad.append({"type": key[0], "name": key[1], "problem": "missing roles: " + ", ".join(sorted(want - have))})
    return bad


def build_load_report(run):
    """The data behind vcfa-load-report.html (the same shape the PowerShell loader builds)."""
    plan, imp = run["plan"], run["imp"]
    direct = plan["directUsers"]
    pending = "planned" if run["mode"] == "dry-run" else "not applied"
    group_rows, user_rows, loaded = [], [], set()
    n_groups = n_users = 0
    for c in plan["creates"] + plan["updates"]:
        is_create = "path" in c and "adding" not in c
        if is_create:
            name = c["body"].get("username") or c["body"]["name"]
            roles, action = [r["name"] for r in c["body"]["roleEntityRefs"]], "create"
        else:
            name, roles, action = c["name"], list(c["adding"]), "add roles"
        row = {"name": name, "action": action, "roles": sorted(roles)}
        if c["type"] == "group":
            n_groups += is_create
            row["result"] = run["results"].get(f"group|{name}", pending)
            group_rows.append(row)
        else:
            n_users += is_create
            row["notInherited"] = list(direct.get(name.lower(), []))
            row["result"] = run["results"].get(f"user|{name}", pending)
            user_rows.append(row)
            loaded.add(name.lower())
    group_rows.sort(key=lambda r: r["name"].lower())
    user_rows.sort(key=lambda r: r["name"].lower())

    skipped_users = {s["name"].lower() for s in plan["skipped"] if s["type"] == "user"}
    own = {b["principal"].lower() for b in imp["roleBindings"] if b["scope"] == "organization" and b["principalType"] == "user"}
    not_loaded = []
    for u in imp["users"]:
        k = u["username"].lower()
        if k in loaded or k in skipped_users:
            continue
        why = "all of their roles come from their groups"
        if run["only"]:
            why = "not selected with -Only"
        elif run["userMode"] == "none":
            why = "groups-only mode"
        elif k not in own:
            why = "no roles of their own"
        not_loaded.append({"name": u["username"], "reason": why})

    skipped = [{"type": s["type"], "name": s["name"], "reason": s["reason"]} for s in plan["skipped"]]
    blocked = blocked_by_missing_roles(plan)
    return {
        "kind": "load", "generatedAt": datetime.now(timezone.utc).isoformat(), "tool": "Python",
        "host": run["host"], "org": run["org"], "importFile": run["importFile"], "mode": run["mode"],
        "userMode": run["userMode"], "only": list(run["only"]), "vcfa": dict(run["vcfa"]),
        "counts": {"groups": n_groups, "users": n_users, "updates": len(plan["updates"]), "skipped": len(skipped),
                   "notLoaded": len(not_loaded), "created": run["created"], "failed": run["failed"],
                   "updated": run["updated"], "updateFailed": run["updateFailed"]},
        "roleMapping": [{"source": k, "target": v} for k, v in sorted(plan["roleMapping"].items())],
        "missingRoles": [{"role": k, "count": v} for k, v in sorted(plan["missingRoles"].items())],
        "blocked": [{"name": n, "roles": list(blocked[n])} for n in sorted(blocked)],
        "groups": group_rows, "users": user_rows, "notLoaded": not_loaded, "skipped": skipped,
        "localUsers": plan["localUsersWithRoles"],
        "projects": [{"project": re.sub(r"^project:", "", k), "bindings": len(v)} for k, v in sorted(plan["projectBindings"].items())],
        "roleCheck": run["roleCheck"], "failures": list(run["failures"]),
    }


def write_html_report(path, data):
    """Fill report-template.html (next to this script) with the data and write one self-contained HTML file."""
    template = os.path.join(os.path.dirname(os.path.abspath(__file__)), "report-template.html")
    if not os.path.exists(template):
        print("  Report skipped: report-template.html was not found next to this script.")
        return False
    with open(template, encoding="utf-8") as f:
        html = f.read()
    payload = json.dumps(data, ensure_ascii=False, separators=(",", ":")).replace("</", "<\\/")
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(html.replace("/*REPORT_DATA*/null", payload))
    print(f"Report: {path}")
    return True


def import_names(limit=15):
    """Short list of names in the import file, to help pick a single group/user for a test."""
    try:
        with open(IMPORT_FILE, encoding="utf-8") as f:
            imp = json.load(f)
    except (OSError, ValueError):
        return ""

    def some(label, items):
        more = f" (+{len(items) - limit} more)" if len(items) > limit else ""
        return f"{len(items)} {label}: " + ", ".join(items[:limit]) + more if items else ""
    return "; ".join(x for x in (some("groups", [g["name"] for g in imp.get("groups", [])]),
                                 some("users", [u["username"] for u in imp.get("users", [])])) if x)


AUTH_METHODS = [
    ("browser", "Browser session token (needed to create users/groups on SSO orgs)"),
    ("file", "Browser token saved in a file (raw token or 'Copy as fetch' capture)"),
    ("api", "Tenant API token"),
    ("provider", "System-org (provider) API token"),
    ("password", "Username and password"),
]
ACTIONS = [
    ("login", "Test login only (checks host, org and credentials; changes nothing)"),
    ("dry", "Dry run (shows the plan, writes vcfa-plan.json; changes nothing)"),
    ("apply", "Apply (really creates groups/users in VCFA)"),
]


def main():
    global VCFA_HOST, IMPORT_FILE
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="really create objects (default is a dry run)")
    ap.add_argument("--allow-missing-roles", action="store_true",
                    help="apply even if some vRA roles do not exist in VCFA (those users get fewer roles)")
    ap.add_argument("--import-file", metavar="FILE", help=f"import file to read (default {IMPORT_FILE})")
    ap.add_argument("--login-only", action="store_true", help="only test the login and exit")
    ap.add_argument("--org", default=None, help="VCFA org/tenant name (prompted if not given)")
    ap.add_argument("--provider", action="store_true",
                    help="VCFA_API_TOKEN is a System-org (provider) token; act inside --org via tenant context")
    ap.add_argument("--bearer-file", metavar="FILE",
                    help="use a browser session token from FILE (raw token or a 'Copy as fetch' capture)")
    ap.add_argument("--browser-token", action="store_true",
                    help="use the browser session token from VCFA_BROWSER_TOKEN (variable in this file, or env)")
    ap.add_argument("--users", action="store_true",
                    help="load ALL users from the import file (default: groups plus only the users whose roles "
                         "are not inherited from their groups)")
    ap.add_argument("--groups-only", action="store_true",
                    help="load groups only, no users at all (users are then created at first SSO login)")
    ap.add_argument("--only", action="append", default=[], metavar="NAME",
                    help="limit to this group or user name (repeatable), e.g. for a one-object trial; "
                         "naming a user includes users")
    args = ap.parse_args()
    if args.users and args.groups_only:
        die("choose either --users (all users) or --groups-only, not both")
    IMPORT_FILE = args.import_file or IMPORT_FILE
    no_flags = len(sys.argv) == 1  # plain "python load_vcfa.py": run the full wizard

    VCFA_HOST = ask_host("VCFA host (FQDN; https:// is added for you)", VCFA_HOST, example="dev.vcfa.local")
    args.org = args.org or ask("VCFA org (tenant) name", ORG, example="finance-org")
    verify = confirm("Verify the TLS certificate? (answer n for a self-signed certificate)", VERIFY_TLS)
    s.verify = verify
    if not verify:
        requests.packages.urllib3.disable_warnings()  # type: ignore[attr-defined]
    if not args.import_file:
        IMPORT_FILE = ask("Import file to load", IMPORT_FILE, example="vcfa-import.json")
    if not args.org:
        die("set the tenant with --org <name> or VCFA_ORG")

    api_token = os.environ.get("VCFA_API_TOKEN") or VCFA_API_TOKEN
    browser_token = os.environ.get("VCFA_BROWSER_TOKEN") or VCFA_BROWSER_TOKEN
    explicit = args.browser_token or args.bearer_file or args.provider
    if no_flags:
        method = choose("How do you want to log in?", AUTH_METHODS)
        if method == "browser":
            args.browser_token = True
            browser_token = ask("Paste the browser token (hidden; just the token, not the whole fetch)",
                                browser_token, secret=True)
        elif method == "file":
            args.bearer_file = ask("Path to the token file", example="C:\\temp\\token.txt")
        elif method in ("api", "provider"):
            args.provider = method == "provider"
            api_token = ask("Paste the API token (hidden)", api_token, secret=True)
        else:  # password: ignore stored tokens so the username/password path is used
            api_token = browser_token = ""
        what = choose("What to import?", [
            ("free", "Groups, plus users whose roles are not inherited from a group (recommended)"),
            ("none", "Groups only (users are then created at first SSO login)"),
            ("all", "Groups and ALL users")])
        args.users, args.groups_only = what == "all", what == "none"
        names = import_names()
        if names:
            print("In " + IMPORT_FILE + ": " + names)
        wanted = ask("Only this group or user (blank = everything, comma-separated for several)",
                     example="Infra-Admins@corp.example.com")
        args.only = [n.strip() for n in wanted.split(",") if n.strip()]
        action = choose("What do you want to do?", ACTIONS, default=2)
        args.login_only, args.apply = action == "login", action == "apply"
        if args.apply and ask("Type 'yes' to really create objects in VCFA") != "yes":
            die("not confirmed; nothing was changed")

    if args.browser_token or (browser_token and not api_token and not explicit):
        if not browser_token:
            browser_token = ask("Paste the browser token (hidden; just the token, not the whole fetch)", secret=True)
        if not browser_token:
            die("--browser-token: no token given (paste it at the prompt, or set VCFA_BROWSER_TOKEN)")
        print(f"Logging in to {VCFA_HOST} with the browser session token ...")
        headers, session = bearer_login(None, args.org, text=browser_token)
    elif args.bearer_file:
        print(f"Logging in to {VCFA_HOST} with the browser session token from {args.bearer_file} ...")
        headers, session = bearer_login(args.bearer_file, args.org)
    elif api_token or args.provider:
        api_token = api_token or ask("Paste the API token (hidden)", secret=True)
        if not api_token:
            die("--provider: no API token given (paste it at the prompt, or set VCFA_API_TOKEN)")
        print(f"Logging in to {VCFA_HOST} org '{args.org}' with an API token ...")
        headers, session = (provider_login if args.provider else token_login)(api_token, args.org)
    else:
        user, pw = credentials()
        print(f"Logging in to {VCFA_HOST} as {user} ...")
        headers, session = login(user, pw, args.org)
    org = session.get("org") or {}
    org_ref = {"name": org.get("name", args.org), "id": org.get("id")}
    # The UI sends these two context headers on every call; the API rejects writes without them (403).
    headers["x-vmware-vcloud-auth-context"] = "system" if args.provider else args.org
    headers["x-vmware-vcloud-tenant-context"] = (org_ref["id"] or "").split(":")[-1]
    print(f"LOGIN OK. Org: {org_ref}  roles on session: {session.get('roles')}")
    if args.login_only:
        return
    with open(IMPORT_FILE, encoding="utf-8") as f:
        imp = json.load(f)

    roles = get_all("/cloudapi/1.0.0/roles", headers)
    users = get_all("/cloudapi/1.0.0/users", headers)
    groups = get_all("/cloudapi/1.0.0/groups", headers)
    print(f"VCFA has {len(roles)} roles, {len(users)} users, {len(groups)} groups")

    plan = build_plan(imp, roles, users, groups, org_ref)
    wanted = {n.lower() for n in args.only}
    if wanted & {u["username"].lower() for u in imp["users"]}:
        args.users, args.groups_only = True, False  # asking for a user by name means "load that user"
    mode = "all" if args.users else ("none" if args.groups_only else "free")
    direct = plan["directUsers"]
    if mode == "none":
        plan["creates"] = [c for c in plan["creates"] if c["type"] == "group"]
        plan["updates"] = [c for c in plan["updates"] if c["type"] == "group"]
    elif mode == "free":  # groups, plus users with roles their groups do not already give them
        plan["creates"] = [c for c in plan["creates"]
                           if c["type"] == "group" or c["body"]["username"].lower() in direct]
        plan["updates"] = [c for c in plan["updates"] if c["type"] == "group" or c["name"].lower() in direct]
    if args.only:
        if mode == "all":
            for g in imp["groups"]:  # a group is only usable with its member users, so pull them in too
                if g["name"].lower() in wanted:
                    wanted |= {m.lower() for m in g.get("members", [])}
        plan["creates"] = [c for c in plan["creates"]
                           if (c["body"].get("username") or c["body"]["name"]).lower() in wanted]
        plan["updates"] = [c for c in plan["updates"] if c["name"].lower() in wanted]
        if not plan["creates"] and not plan["updates"]:
            die(f"--only {args.only}: nothing to create or update (name not in the import file, or already up to date)")
    n_u = sum(c["type"] == "user" for c in plan["creates"])
    n_g = sum(c["type"] == "group" for c in plan["creates"])
    print(f"Plan: create {n_u} users, {n_g} groups; skip {len(plan['skipped'])}; "
          f"add roles to {len(plan['updates'])} existing")
    loaded_users = sorted({(c["body"].get("username") or c["name"] if "body" in c else c["name"]).lower()
                           for c in plan["creates"] + plan["updates"] if c["type"] == "user"})
    if mode == "free":
        print(f"Users loaded because their roles are not inherited from a group: {len(loaded_users)}"
              + ("" if not loaded_users else " (" + "; ".join(
                  f"{n}: {', '.join(direct.get(n, []))}" for n in loaded_users[:15])
                 + (f"; +{len(loaded_users) - 15} more" if len(loaded_users) > 15 else "") + ")"))
    elif mode == "none":
        print("Users: none (--groups-only). They are created at their first SSO login, without direct roles.")
    if plan["localUsersWithRoles"] and mode != "none":
        print("Local users with roles are NOT created (they need passwords); create them by hand in VCFA: "
              + "; ".join(f"{u['name']} ({', '.join(u['roles'])})" for u in plan["localUsersWithRoles"]))
    print("Role mapping (role in the import file -> VCFA role):")
    for src, dst in sorted(plan["roleMapping"].items()):
        print(f"  {src} -> {dst or 'NOT FOUND in VCFA'}")
    if plan["projectBindingsNotHandled"]:
        print(f"Project roles ({plan['projectBindingsNotHandled']} in {len(plan['projectBindings'])} projects) are only "
              f"recorded in the export, never loaded; listed under projectBindings in {PLAN_FILE}")
    if plan["missingRoles"]:
        print("Roles not found in VCFA (fix ROLE_MAP in export_vra_identity.py):")
        for name, n in sorted(plan["missingRoles"].items()):
            print(f"  {name}: {n}")
    print("VCFA role names available:", sorted(r["name"] for r in roles))
    for c in plan["updates"]:
        print(f"  update {c['type']} {c['name']}: add {', '.join(c['adding'])}")

    blocked = blocked_by_missing_roles(plan)
    if blocked:
        print(f"{len(blocked)} planned objects would get FEWER roles than in vRA because the role does not exist in VCFA:")
        for name, rs in sorted(blocked.items()):
            print(f"  {name}: {', '.join(rs)}")
    with open(PLAN_FILE, "w", encoding="utf-8") as f:
        json.dump(plan, f, indent=2)
    run = {"host": VCFA_HOST, "org": org_ref["name"], "importFile": IMPORT_FILE, "mode": "dry-run", "userMode": mode,
           "only": list(args.only), "vcfa": {"roles": len(roles), "users": len(users), "groups": len(groups)},
           "plan": plan, "imp": imp, "results": {}, "failures": [], "roleCheck": None,
           "created": 0, "failed": 0, "updated": 0, "updateFailed": 0}
    if not args.apply:
        print(f"DRY RUN - nothing created. Wrote {PLAN_FILE}. Re-run with --apply to create.")
        write_html_report(REPORT_FILE, build_load_report(run))
        return
    if blocked and not args.allow_missing_roles:
        run["mode"] = "blocked"
        write_html_report(REPORT_FILE, build_load_report(run))
        die("not applying: fix ROLE_MAP (or create the roles in VCFA), or pass --allow-missing-roles to accept fewer roles")
    run["mode"] = "applied"

    for c in plan["creates"]:
        status, body = post(c["path"], headers, c["body"])
        name = c["body"].get("username") or c["body"]["name"]
        if status in (200, 201):
            run["created"] += 1
            run["results"][f"{c['type']}|{name}"] = "created"
        else:
            run["failed"] += 1
            run["results"][f"{c['type']}|{name}"] = f"failed (HTTP {status})"
            run["failures"].append({"type": c["type"], "name": name, "detail": f"HTTP {status} {json.dumps(body)[:200]}"})
            print(f"  FAILED {c['type']} {name}: {status} {json.dumps(body)[:200]}")
    print(f"Done: {run['created']} created, {run['failed']} failed")
    for c in plan["updates"]:
        r = s.put(f"{VCFA_HOST}{c['path']}", headers=headers, data=json.dumps(c["body"]), timeout=TIMEOUT)
        if r.status_code in (200, 201):
            run["updated"] += 1
            run["results"][f"{c['type']}|{c['name']}"] = "updated"
        else:
            run["updateFailed"] += 1
            run["results"][f"{c['type']}|{c['name']}"] = f"failed (HTTP {r.status_code})"
            run["failures"].append({"type": c["type"], "name": c["name"], "detail": f"update HTTP {r.status_code} {r.text[:200]}"})
            print(f"  FAILED update {c['type']} {c['name']}: {r.status_code} {r.text[:200]}")
    if plan["updates"]:
        print(f"Roles added on existing objects: {run['updated']} updated, {run['updateFailed']} failed")
    bad = verify_roles(plan, headers)
    total = len(expected_roles(plan))
    print(f"Role check: {total - len(bad)}/{total} objects have the same org/service roles as in vRA")
    for b in bad:
        print(f"  MISMATCH {b['type']} {b['name']}: {b['problem']}")
    run["roleCheck"] = {"total": total, "matched": total - len(bad), "mismatches": bad}
    write_html_report(REPORT_FILE, build_load_report(run))
    if plan["projectBindingsNotHandled"]:
        print(f"Note: {plan['projectBindingsNotHandled']} project role bindings are recorded only; this script does not load projects.")


if __name__ == "__main__":
    main()
