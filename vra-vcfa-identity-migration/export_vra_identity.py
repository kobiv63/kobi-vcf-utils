"""Export users, groups and roles from vRA 8.x to JSON (raw + VCFA-shaped).

Run it and answer the prompts (each one shows a default you can accept with Enter):
    python export_vra_identity.py              # menu: test login / list users / list groups / full export
    python export_vra_identity.py login        # skip the menu: login|users|groups|domains|all
Defaults come from the env vars VRA_HOST, VRA_USERNAME, VRA_PASSWORD, VRA_DOMAIN, VRA_DOMAINS, VRA_VERIFY_TLS or the constants below.
When stdin is not a terminal nothing is prompted and the defaults are used.
Output files are written to the folder you run the script from.
"""
import base64
import getpass
import json
import os
import re
import sys
from datetime import datetime, timezone

import requests


def flag_setting(text, default):
    """Reads a yes/no setting from an env var: true/false, yes/no, y/n, 1/0 or on/off. Anything else gives the default."""
    t = (text or "").strip().lower()
    if t in ("true", "yes", "y", "1", "on"):
        return True
    if t in ("false", "no", "n", "0", "off"):
        return False
    return default


def domain_list(text):
    """'all' or blank = no filter (empty list); otherwise the comma-separated names, trimmed."""
    t = (text or "").strip()
    if not t or t.lower() == "all":
        return []
    return [d.strip() for d in t.split(",") if d.strip()]

# ---- Config -----------------------------------------------------------------
# Every value below is asked for in the terminal; what you set here (or in an env var) is only the default.
VRA_HOST = os.environ.get("VRA_HOST", "https://vra.example.com")  # e.g. "dev.vra.local" (https:// is added if missing; env VRA_HOST)
USERNAME = ""          # e.g. "configurationadmin" (env VRA_USERNAME)
PASSWORD = ""          # leave empty to be prompted; never commit it (env VRA_PASSWORD)
DOMAIN = ""            # vIDM domain the login account belongs to, e.g. "System Domain" or "corp.example.com" (env VRA_DOMAIN)
# Domains to include in the export (case-insensitive), e.g. ["System Domain", "corp.example.com"]. Empty list = everything.
# One admin login returns principals from all vIDM domains assigned to the org.
INCLUDE_DOMAINS = ["System Domain", "corp.example.com"]  # TODO: set your custom domain (env VRA_DOMAINS overrides it; "all" = everything)
VERIFY_TLS = flag_setting(os.environ.get("VRA_VERIFY_TLS"), False)  # asked at the prompt; False accepts a self-signed certificate (lab). e.g. True for a CA-signed cert (env VRA_VERIFY_TLS)
TIMEOUT = 30           # seconds per request (not asked); e.g. 120 for a slow appliance
OUTPUT_DIR = os.getcwd()  # asked at the prompt; default is the folder you run the script from, e.g. r"C:\exports\customer1"

# vRA role -> VCFA role. Unmapped roles end up in "warnings" of the import file.
# TODO: confirm target role names against your VCFA organization.
ROLE_MAP = {
    # Org roles (VM Apps org in VCFA)
    "org_owner": "Organization Owner",
    "org_member": "Organization Member",
    # Service roles
    "automationservice:cloud_admin": "Assembler Administrator",
    "automationservice:user": "Assembler User",
    "automationservice:viewer": "Assembler Viewer",
    "catalog:admin": "Service Broker Administrator",
    "catalog:user": "Service Broker User",
    "catalog:viewer": "Service Broker Viewer",
    "orchestration:admin": "Orchestrator Administrator",
    "orchestration:designer": "Orchestrator Workflow Designer",
    "orchestration:viewer": "Orchestrator Viewer",
    # Project roles (assigned via project membership in VCFA; the loader does not handle these yet)
    "project:administrators": "Project Administrator",
    "project:members": "Project User",
    "project:viewers": "Project Viewer",
    "project:supervisors": "Project Supervisor",
    # migration:admin has no VCFA equivalent: left unmapped so it shows up as a warning.
}
DIRECTORY_PROVIDER_TYPE = "OAUTH"  # providerType for non-System-Domain users/groups in VCFA; asked at the prompt: OAUTH, LDAP or SAML
# Roles from these services are intentionally not migrated (no warning raised).
IGNORE_ROLE_PREFIXES = ("saltstack:", "codestream:")

# Candidate CSP endpoints (first one returning 200 wins). Verify against the
# appliance Swagger if the export comes back empty.
USER_PATHS = [
    "/csp/gateway/am/api/v2/orgs/{org}/users",
    "/csp/gateway/am/api/orgs/{org}/users",
]
GROUP_PATHS = [
    "/csp/gateway/am/api/v2/orgs/{org}/groups",
    "/csp/gateway/am/api/orgs/{org}/groups",
    "/csp/gateway/am/api/v3/orgs/{org}/groups",
]

if not VERIFY_TLS:
    requests.packages.urllib3.disable_warnings()  # type: ignore[attr-defined]

session = requests.Session()
session.verify = VERIFY_TLS


def die(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


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


def login(username, password, domain):
    r = session.post(
        f"{VRA_HOST}/csp/gateway/am/api/login?access_token",
        json={"username": username, "password": password, "domain": domain},
        timeout=TIMEOUT,
    )
    if r.status_code != 200:
        die(f"login failed ({r.status_code}): {r.text[:300]}")
    refresh_token = r.json()["refresh_token"]

    r = session.post(
        f"{VRA_HOST}/csp/gateway/am/api/auth/api-tokens/authorize",
        data={"refresh_token": refresh_token},
        timeout=TIMEOUT,
    )
    if r.status_code != 200:
        die(f"token authorize failed ({r.status_code}): {r.text[:300]}")
    csp_token = r.json()["access_token"]

    r = session.post(f"{VRA_HOST}/iaas/api/login", json={"refreshToken": refresh_token}, timeout=TIMEOUT)
    if r.status_code != 200:
        die(f"iaas login failed ({r.status_code}): {r.text[:300]}")
    return csp_token, r.json()["token"]


def get_json(path, token, params=None):
    r = session.get(
        f"{VRA_HOST}{path}",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
        params=params,
        timeout=TIMEOUT,
    )
    return r


def items_of(body):
    """CSP/IaaS list responses use different keys; normalise to a list."""
    if isinstance(body, list):
        return body
    for key in ("results", "content", "items", "values"):
        if key in body and isinstance(body[key], list):
            return body[key]
    return []


def get_all(path, token, page_size=100, max_pages=50):
    """Fetch all pages, de-duplicated. Stops when a page adds nothing new (API may ignore paging)."""
    out, seen, page = [], set(), 0
    while page < max_pages:
        r = get_json(path, token, {"page": page, "size": page_size})
        if r.status_code != 200:
            return out, r.status_code
        body = r.json()
        batch = items_of(body)
        new = [x for x in batch if json.dumps(x, sort_keys=True) not in seen]
        if not new:
            break
        seen.update(json.dumps(x, sort_keys=True) for x in new)
        out.extend(new)
        total_pages = body.get("totalPages") if isinstance(body, dict) else None
        page += 1
        if len(batch) < page_size or (total_pages is not None and page >= total_pages):
            break
    return out, 200


def first_working(paths, org, token):
    for p in paths:
        path = p.format(org=org)
        items, status = get_all(path, token)
        if status == 200:
            return path, items
        print(f"  {path} -> {status}")
    return None, []


def get_org_id(token):
    r = get_json("/csp/gateway/am/api/loggedin/user/orgs", token)
    if r.status_code != 200:
        die(f"could not list orgs ({r.status_code}): {r.text[:300]}")
    body = r.json()
    if isinstance(body, dict) and body.get("refLinks"):
        return body["refLinks"][0].rstrip("/").split("/")[-1]
    orgs = items_of(body)
    if not orgs and isinstance(body, dict):
        orgs = [body] if (body.get("id") or body.get("orgId")) else []
        if not orgs:
            for v in body.values():
                if isinstance(v, list) and v and isinstance(v[0], dict):
                    orgs = v
                    break
    if orgs:
        return orgs[0].get("id") or orgs[0].get("orgId")
    # Fallback: the CSP access token carries the org id as 'context_name'
    try:
        payload = token.split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
        if claims.get("context_name"):
            return claims["context_name"]
    except Exception:
        pass
    die(f"no orgs found; raw response: {json.dumps(body)[:500]}")


def role_names(obj):
    """Collect role names from the various role fields a CSP object may carry."""
    names = []
    for key in ("organizationRoles", "serviceRoles", "roles"):
        for role in obj.get(key) or []:
            if isinstance(role, str):
                names.append(role)
            elif isinstance(role, dict):
                if role.get("name"):
                    names.append(role["name"])
                names.extend(role.get("serviceRoleNames") or [])
                for sub in role.get("serviceRoles") or []:
                    if isinstance(sub, dict) and sub.get("name"):
                        names.append(sub["name"])
    return names


def principal_domain(p):
    """Best-effort domain of a user/group; CSP objects vary in which field is set."""
    p = p.get("user") or p  # users are nested under "user"
    d = p.get("domain") or p.get("identityProviderDomain")
    if d:
        return d
    for key in ("username", "email", "name"):
        v = p.get(key) or ""
        if "@" in v:
            return v.split("@", 1)[1]
    return "System Domain"


def in_scope(p):
    if not INCLUDE_DOMAINS:
        return True
    return principal_domain(p).lower() in {d.lower() for d in INCLUDE_DOMAINS}


def principal_name(p):
    p = p.get("user") or p
    return p.get("email") or p.get("username") or p.get("displayName") or p.get("name") or p.get("userId") or p.get("id")


def is_ignored(role):
    return role.lower().startswith(IGNORE_ROLE_PREFIXES)


def summarize(p):
    """Flat view of a user or group with its org and service role names (ignored services removed)."""
    is_user = "user" in p
    u = p.get("user") or p
    out = {"id": u.get("userId") if is_user else p.get("id")}
    if is_user:
        out.update({"username": u.get("username"), "domain": principal_domain(p), "email": u.get("email"),
                    "firstName": u.get("firstName"), "lastName": u.get("lastName")})
    else:
        out.update({"name": principal_name(p), "domain": principal_domain(p), "groupType": p.get("groupType")})
    if not is_user:
        out["members"] = [upn(x) for x in p.get("members") or [] if x.get("username")]
    out["organizationRoles"] = [r.get("name") for r in p.get("organizationRoles") or [] if isinstance(r, dict)]
    out["serviceRoles"] = [r for r in role_names({"serviceRoles": p.get("serviceRoles")}) if not is_ignored(r)]
    return {k: v for k, v in out.items() if v not in (None, "")}


def trim_user(p):
    """Raw user minus empty/duplicate fields (acct, idpId, accessible, userProfile, per-user orgId)."""
    u = p.get("user") or {}
    keep = ("username", "firstName", "lastName", "domain", "email", "userId")
    return {"user": {k: u.get(k) for k in keep if u.get(k)},
            "organizationRoles": p.get("organizationRoles") or [], "serviceRoles": p.get("serviceRoles") or []}


def trim_project(pr):
    keep = ("id", "name", "description", "administrators", "members", "viewers", "supervisors")
    return {k: pr[k] for k in keep if pr.get(k)}


def upn(u):
    """VCFA usernames for federated users are the full UPN, e.g. olga@corp.example.com."""
    name, dom = (u.get("user") or u).get("username") or "", principal_domain(u)
    return name if "@" in name or dom.lower() == "system domain" else f"{name}@{dom}"


def build_import(users, groups, projects, all_users=None, default_domain=""):
    """Build the VCFA import. Project members arrive from the IaaS API as bare usernames (no domain), so they are
    matched against all known users (`all_users`, in-scope users, group members). Project-only users that match
    are added to `users` with an org_member binding so they can exist in VCFA. Names that match nothing get
    `default_domain` appended if given, else they are listed in `unresolvedProjectUsers` and the warnings."""
    warnings, bindings = [], []

    def bind(kind, name, scope, vra_role):
        if is_ignored(vra_role):
            return
        vcfa_role = ROLE_MAP.get(vra_role)
        if vcfa_role is None:
            warnings.append(f"unmapped role '{vra_role}' for {kind} '{name}' ({scope})")
            return
        bindings.append({"principalType": kind, "principal": name, "scope": scope, "role": vcfa_role,
                         "vraRole": vra_role})

    for u in users:
        for role in role_names(u):
            bind("user", upn(u), "organization", role)
    for g in groups:
        for role in role_names(g):
            bind("group", principal_name(g), "organization", role)
    def provider(domain):
        # vRA System Domain accounts are local; directory accounts are federated into VCFA via OIDC.
        # VCFA reports OIDC identities as providerType OAUTH (use "LDAP" or "SAML" for those org types).
        return "LOCAL" if domain.lower() == "system domain" else DIRECTORY_PROVIDER_TYPE

    imp = {
        "users": [{"username": upn(u), "fullName": " ".join(filter(None, [(u.get("user") or u).get("firstName"), (u.get("user") or u).get("lastName")])) or None,
                   "email": (u.get("user") or u).get("email"), "domain": principal_domain(u),
                   "providerType": provider(principal_domain(u))} for u in users],
        "groups": [{"name": principal_name(g), "domain": principal_domain(g),
                    "providerType": provider(principal_domain(g)),
                    "members": sorted({upn(x) for x in g.get("members") or [] if x.get("username")})} for g in groups],
        "roleBindings": bindings,
    }
    imp["users"] = [{k: v for k, v in x.items() if v} for x in imp["users"]]
    have = {x["username"].lower() for x in imp["users"]}
    for g in groups:  # members that are not org users themselves still need to exist in VCFA
        for x in g.get("members") or []:
            if x.get("username") and upn(x).lower() not in have:
                have.add(upn(x).lower())
                imp["users"].append({k: v for k, v in {
                    "username": upn(x), "email": x.get("email"), "domain": principal_domain(x),
                    "fullName": " ".join(filter(None, [x.get("firstName"), x.get("lastName")])) or None,
                    "providerType": provider(principal_domain(x))}.items() if v})
    # Project roles. Groups keep their name; users are resolved to a UPN and added to the import if missing.
    directory = {}
    for x in list(users) + list(all_users or []) + [mm for g in groups for mm in g.get("members") or []]:
        base = (x.get("user") or x)
        for key in (base.get("username"), base.get("email"), upn(x) if base.get("username") else None):
            if key:
                directory.setdefault(key.lower(), x)
    org_bound = {b["principal"].lower() for b in bindings if b["scope"] == "organization" and b["principalType"] == "user"}
    unresolved, project_only = set(), []

    def project_user(name):
        found = directory.get(name.lower())
        if found:
            principal, domain, rec = upn(found), principal_domain(found), found
        elif default_domain:
            principal = name if "@" in name else f"{name}@{default_domain}"
            domain, rec = default_domain, {"username": principal}
        else:
            unresolved.add(name)
            return None
        if principal.lower() not in have:
            have.add(principal.lower())
            project_only.append(principal)
            imp["users"].append({k: v for k, v in {
                "username": principal, "email": (rec.get("user") or rec).get("email"), "domain": domain,
                "fullName": " ".join(filter(None, [(rec.get("user") or rec).get("firstName"), (rec.get("user") or rec).get("lastName")])) or None,
                "providerType": provider(domain)}.items() if v})
        return principal

    for proj in projects:
        for field in ("administrators", "members", "viewers", "supervisors"):
            for p in proj.get(field) or []:
                name = p.get("email") or p.get("name")
                if not name:
                    continue
                scope = f"project:{proj.get('name')}"
                if p.get("type") == "group":
                    bind("group", name, scope, f"project:{field}")
                else:
                    principal = project_user(name)
                    if principal:
                        bind("user", principal, scope, f"project:{field}")
    for principal in project_only:  # a user needs an org role to exist in VCFA; project access implies org membership
        if principal.lower() not in org_bound:
            bind("user", principal, "organization", "org_member")
    for name in sorted(unresolved):
        warnings.append(f"project member '{name}' not found among vRA users (domain unknown): not imported")
    if unresolved:
        imp["unresolvedProjectUsers"] = sorted(unresolved)
    if project_only:
        imp["projectOnlyUsers"] = sorted(project_only)
    # Which groups each user belongs to (informational; the loader uses it to tell direct roles from inherited ones).
    member_of = {}
    for g in groups:
        for x in g.get("members") or []:
            if x.get("username"):
                member_of.setdefault(upn(x).lower(), set()).add(principal_name(g))
    for u in imp["users"]:
        groups_of = member_of.get(u["username"].lower())
        if groups_of:
            u["memberOf"] = sorted(groups_of)
    if warnings:
        imp["warnings"] = warnings
    return imp


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


def build_export_report(imp, users, groups, projects, users_all, groups_all, org, domains_seen, files,
                        failed_members, output_dir, endpoints):
    """The data behind vra-export-report.html (the same shape the PowerShell export builds)."""
    org_roles = {}
    for b in imp["roleBindings"]:
        if b["scope"] == "organization":
            org_roles.setdefault((b["principalType"], b["principal"].lower()), set()).add(b["role"])

    def roles_of(kind, name):
        return sorted(org_roles.get((kind, name.lower()), []))

    project_only = {n.lower() for n in imp.get("projectOnlyUsers", [])}
    rmap, unmapped = {}, {}
    for b in imp["roleBindings"]:
        scope = "organization" if b["scope"] == "organization" else "project"
        row = rmap.setdefault(f"{b['vraRole']}|{scope}", {"vraRole": b["vraRole"], "role": b["role"], "scope": scope, "bindings": 0})
        row["bindings"] += 1
    for w in imp.get("warnings", []):
        m = re.match(r"^unmapped role '(.*?)' for .*\((.*)\)$", w)
        if not m:
            continue
        scope = "organization" if m.group(2) == "organization" else "project"
        row = rmap.setdefault(f"{m.group(1)}|{scope}", {"vraRole": m.group(1), "role": None, "scope": scope, "bindings": 0})
        row["bindings"] += 1
        unmapped[m.group(1)] = unmapped.get(m.group(1), 0) + 1

    def count(items):
        return len([x for x in items or [] if x])

    attention = []
    if failed_members:
        attention.append({"tone": "warn", "title": 'Group member lists that could not be read. Users in these groups may later look "not inherited from a group" and be loaded directly.',
                          "items": [f"{f['name']} (HTTP {f['status']})" for f in failed_members]})
    if unmapped:
        attention.append({"tone": "warn", "title": "vRA roles with no VCFA equivalent. They are not migrated.",
                          "items": [f"{r} ({unmapped[r]} use(s))" for r in sorted(unmapped)]})
    if "unresolvedProjectUsers" in imp:
        attention.append({"tone": "warn", "title": "Project members that were not found among the vRA users (domain unknown). They are not imported.",
                          "items": list(imp["unresolvedProjectUsers"])})
    if "projectOnlyUsers" in imp:
        attention.append({"tone": "info", "title": "Users added because they only have project access. They get the Organization Member role so they can exist in VCFA.",
                          "items": list(imp["projectOnlyUsers"])})
    return {
        "kind": "export", "generatedAt": datetime.now(timezone.utc).isoformat(), "tool": "Python",
        "host": VRA_HOST, "org": org, "outputDir": output_dir,
        "counts": {"users": len(users), "usersAll": users_all, "usersInImport": len(imp["users"]), "groups": len(groups),
                   "groupsAll": groups_all, "projects": len(projects), "bindings": len(imp["roleBindings"]),
                   "warnings": len(imp.get("warnings", []))},
        "domainsSeen": list(domains_seen), "domainsSelected": list(INCLUDE_DOMAINS), "providerType": DIRECTORY_PROVIDER_TYPE,
        "endpoints": {"users": endpoints["users"], "groups": endpoints["groups"]},
        "attention": attention,
        "roleMapping": [rmap[k] for k in sorted(rmap)],
        "groups": [{"name": principal_name(g), "domain": principal_domain(g), "type": g.get("groupType"),
                    "members": count(g.get("members")), "roles": roles_of("group", principal_name(g))} for g in groups],
        "users": [{"name": u["username"], "domain": u.get("domain"), "memberOf": list(u.get("memberOf", [])),
                   "roles": roles_of("user", u["username"]), "projectOnly": u["username"].lower() in project_only}
                  for u in imp["users"]],
        "projects": [{"name": p.get("name"), "administrators": count(p.get("administrators")), "members": count(p.get("members")),
                      "viewers": count(p.get("viewers")), "supervisors": count(p.get("supervisors"))} for p in projects],
        "files": list(files),
    }


def dump(name, data):
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    path = os.path.join(OUTPUT_DIR, name)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
    print(f"Wrote {path}")


STEPS = [
    ("login", "Test login only (checks host, username, password and domain)"),
    ("users", "List users (shows raw output to check the API works)"),
    ("groups", "List groups (shows raw output to check the API works)"),
    ("domains", "List the vIDM domains in vRA (no export; choose which to export)"),
    ("all", "Full export (writes vcfa-import.json and backups)"),
]


def domain_lines(users, groups):
    """One line per vIDM domain, in the form the browser page reads: DOMAIN: <name> | users <n> | groups <m>."""
    user_counts, group_counts = {}, {}
    for u in users:
        d = principal_domain(u)
        user_counts[d] = user_counts.get(d, 0) + 1
    for g in groups:
        d = principal_domain(g)
        group_counts[d] = group_counts.get(d, 0) + 1
    names = sorted(set(user_counts) | set(group_counts), key=str.lower)
    return [f"DOMAIN: {d} | users {user_counts.get(d, 0)} | groups {group_counts.get(d, 0)}" for d in names]


def main():
    global VRA_HOST, INCLUDE_DOMAINS, OUTPUT_DIR, DIRECTORY_PROVIDER_TYPE
    # Usage: python export_vra_identity.py [login|users|groups|all]   (no argument = menu)
    step = sys.argv[1] if len(sys.argv) > 1 else choose("What do you want to do?", STEPS, default=5)
    if step not in {s for s, _ in STEPS}:
        die(f"unknown step '{step}', use one of: {', '.join(s for s, _ in STEPS)}")

    VRA_HOST = ask_host("vRA host (FQDN; https:// is added for you)", VRA_HOST, example="dev.vra.local")
    verify = confirm("Verify the TLS certificate? (answer n for a self-signed certificate)",
                     flag_setting(os.environ.get("VRA_VERIFY_TLS"), VERIFY_TLS))
    session.verify = verify
    if not verify:
        requests.packages.urllib3.disable_warnings()  # type: ignore[attr-defined]
    username = ask("vRA username", USERNAME or os.environ.get("VRA_USERNAME", ""), example="configurationadmin")
    password = PASSWORD or os.environ.get("VRA_PASSWORD") or ask("vRA password", secret=True)
    domain = ask("vIDM domain of the login account", os.environ.get("VRA_DOMAIN") or DOMAIN,
                 example="System Domain or corp.example.com")
    if step not in ("login", "domains"):
        OUTPUT_DIR = ask("Folder for the output files", OUTPUT_DIR, example=r"C:\exports\customer1")
    if step == "all":
        shown = os.environ.get("VRA_DOMAINS") or ", ".join(INCLUDE_DOMAINS) or "all"
        answer = ask("Domains to export (comma-separated, or 'all')", shown, example="corp.example.com, System Domain")
        INCLUDE_DOMAINS = domain_list(answer)
        DIRECTORY_PROVIDER_TYPE = ask("How VCFA authenticates directory users/groups (OAUTH, LDAP or SAML)",
                                      DIRECTORY_PROVIDER_TYPE).upper()
        if DIRECTORY_PROVIDER_TYPE not in ("OAUTH", "LDAP", "SAML"):
            die(f"provider type must be OAUTH, LDAP or SAML, not '{DIRECTORY_PROVIDER_TYPE}'")
    if not (username and password):
        die("username and password are required")

    print(f"Logging in to {VRA_HOST} ...")
    csp_token, iaas_token = login(username, password, domain)
    org = get_org_id(csp_token)
    print(f"LOGIN OK. Org: {org}")
    if step == "login":
        return

    if step == "domains":
        print("Fetching users and groups to list their domains ...")
        _, all_users = first_working(USER_PATHS, org, csp_token)
        _, all_groups = first_working(GROUP_PATHS, org, csp_token)
        print("Domains in vRA (set VRA_DOMAINS to all, or to a comma-separated list of these names):")
        lines = domain_lines(all_users, all_groups)
        if not lines:
            print("  No users or groups were found, so there are no domains.")
        for line in lines:
            print(line)
        return

    if step in ("users", "groups"):
        paths = USER_PATHS if step == "users" else GROUP_PATHS
        path, items = first_working(paths, org, csp_token)
        print(f"  {len(items)} {step} via {path}")
        counts = {}
        for x in items:
            d = principal_domain(x)
            counts[d] = counts.get(d, 0) + 1
        print(f"  by domain: {counts}")
        if items:
            print("  first item keys:", sorted(items[0].keys()))
            print("  first item:", json.dumps(items[0])[:800])
        dump(f"step-{step}.json", {"endpoint": path, "items": items})
        return

    print("Fetching users ...")
    user_path, users = first_working(USER_PATHS, org, csp_token)
    all_users = users
    users = [u for u in all_users if in_scope(u)]
    print(f"  {len(users)}/{len(all_users)} users in selected domains via {user_path}")

    print("Fetching groups ...")
    group_path, groups = first_working(GROUP_PATHS, org, csp_token)
    all_groups = groups
    groups = [g for g in all_groups if in_scope(g)]
    failed_members = []
    for g in groups:
        members, status = get_all(f"{group_path}/{g['id']}/users", csp_token)
        if status != 200:
            failed_members.append({"name": principal_name(g), "status": status})
        g["members"] = [{k: x.get(k) for k in ("userId", "username", "domain", "email", "firstName", "lastName") if x.get(k)}
                        for x in members] if status == 200 else []
    print(f"  {len(groups)}/{len(all_groups)} groups in selected domains via {group_path}")
    if failed_members:
        print(f"  WARNING: the member list of {len(failed_members)} group(s) could not be read: "
              f"{', '.join(f['name'] for f in failed_members)}. Users in them may later be loaded as 'not inherited from a group'.")
    seen = sorted({principal_domain(x) for x in all_users + all_groups})
    print(f"  domains seen: {seen}")

    print("Fetching projects ...")
    projects, status = get_all("/iaas/api/projects", iaas_token)
    if status != 200:
        print(f"  projects returned {status}; skipping project roles")
    print(f"  {len(projects)} projects")

    raw = {
        "meta": {
            "host": VRA_HOST,
            "orgId": org,
            "exportedAt": datetime.now(timezone.utc).isoformat(),
            "userEndpoint": user_path,
            "groupEndpoint": group_path,
        },
        "users": [trim_user(u) for u in users],
        "groups": groups,
        "projects": [trim_project(pr) for pr in projects],
    }
    imp = build_import(users, groups, projects, all_users)
    if imp.get("unresolvedProjectUsers"):
        print(f"  {len(imp['unresolvedProjectUsers'])} project users not found among vRA users: "
              f"{', '.join(imp['unresolvedProjectUsers'])}")
        dom = ask("Domain to use for these users (blank = skip them)",
                  os.environ.get("VRA_PROJECT_USER_DOMAIN", ""), example="corp.example.com")
        if dom:
            imp = build_import(users, groups, projects, all_users, default_domain=dom)
    if imp.get("projectOnlyUsers"):
        print(f"  {len(imp['projectOnlyUsers'])} users have project access but no org role or group; added to the import")

    os.makedirs(OUTPUT_DIR, exist_ok=True)
    files = (
        ("vra-export.json", raw),
        ("vcfa-import.json", imp),
        ("users.json", [summarize(u) for u in users]),
        ("groups.json", [summarize(g) for g in groups]),
    )
    written = []
    for name, data in files:
        path = os.path.join(OUTPUT_DIR, name)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
        print(f"Wrote {path}")
        written.append(os.path.abspath(path))
    if imp.get("warnings"):
        print(f"{len(imp['warnings'])} warnings (unmapped roles) - see vcfa-import.json")
    report_path = os.path.join(OUTPUT_DIR, "vra-export-report.html")
    report = build_export_report(imp, users, groups, projects, len(all_users), len(all_groups), org, seen,
                                 written + [os.path.abspath(report_path)], failed_members, os.path.abspath(OUTPUT_DIR),
                                 {"users": user_path, "groups": group_path})
    write_html_report(report_path, report)


if __name__ == "__main__":
    main()
