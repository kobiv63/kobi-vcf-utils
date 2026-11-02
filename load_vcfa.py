"""Load vcfa-import.json into VCF Automation (VCFA) via the cloudapi. DRY RUN by default.

    python load_vcfa.py                 # dry run: log in, resolve roles, show what would be created
    python load_vcfa.py --apply         # actually create users/groups and assign org roles

Reads vcfa-import.json from the current folder. Writes vcfa-plan.json (the exact requests) in dry-run.
Credentials: VCFA_USERNAME / VCFA_PASSWORD env vars, else USERNAME / PASSWORD from export_vra_identity.py.
Org (tenant): VCFA_ORG env var or ORG below.
"""
import argparse
import base64
import json
import os
import sys

import requests

VCFA_HOST = os.environ.get("VCFA_HOST", "https://vcfa.example.com")
ORG = os.environ.get("VCFA_ORG", "my-org")   # tenant/org name
VERIFY_TLS = False
TIMEOUT = 30
API_VERSION = os.environ.get("VCFA_API_VERSION", "40.0")
IMPORT_FILE = "vcfa-import.json"
PLAN_FILE = "vcfa-plan.json"
VCFA_API_TOKEN = ""  # for OIDC/SSO orgs: paste an API token created in the VCFA UI (or set env VCFA_API_TOKEN)
VCFA_BROWSER_TOKEN = ""  # browser session token (raw, or a 'Copy as fetch' capture); or set env VCFA_BROWSER_TOKEN
VCFA_USERNAME = ""          # e.g. "configurationadmin"
VCFA_PASSWORD = ""          # leave empty to be prompted
if not VERIFY_TLS:
    requests.packages.urllib3.disable_warnings()  # type: ignore[attr-defined]
s = requests.Session()
s.verify = VERIFY_TLS


def die(msg):
    sys.exit(f"ERROR: {msg}")


def credentials():
    user = os.environ.get("VCFA_USERNAME") or VCFA_USERNAME
    pw = os.environ.get("VCFA_PASSWORD") or VCFA_PASSWORD
    if not (user and pw):
        import export_vra_identity as e  # reuse the lab credentials already kept there
        user, pw = user or e.USERNAME, pw or e.PASSWORD
    if not (user and pw):
        die("no credentials: set VCFA_USERNAME/VCFA_PASSWORD or fill USERNAME/PASSWORD in export_vra_identity.py")
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
    m = re.search(r'"authorization"\s*:\s*"Bearer\s+([^"]+)"', text, re.I)
    token = (m.group(1) if m else text.strip().removeprefix("Bearer ").strip())
    if not token or len(token) < 20:
        die(f"no bearer token found in {path or 'VCFA_BROWSER_TOKEN'}")
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


def build_plan(imp, roles, existing_users, existing_groups, org_ref):
    role_ids = {r["name"].lower(): r["id"] for r in roles}
    have_users = {(u.get("username") or "").lower(): u for u in existing_users}
    have_groups = {(g.get("name") or "").lower(): g for g in existing_groups}

    org_roles = {}  # (type, principal) -> [vcfa role names]
    skipped_project = 0
    for b in imp["roleBindings"]:
        if b["scope"] != "organization":
            skipped_project += 1
            continue
        org_roles.setdefault((b["principalType"], b["principal"]), []).append(b["role"])

    missing_roles, creates, skipped, updates = {}, [], [], []

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
            rid = role_ids.get(name.lower())
            if rid:
                out.append({"name": name, "id": rid})
            else:
                missing_roles[name] = missing_roles.get(name, 0) + 1
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

    return {"creates": creates, "updates": updates, "skipped": skipped, "missingRoles": missing_roles,
            "projectBindingsNotHandled": skipped_project}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="really create objects (default is a dry run)")
    ap.add_argument("--org", default=ORG)
    ap.add_argument("--provider", action="store_true",
                    help="VCFA_API_TOKEN is a System-org (provider) token; act inside --org via tenant context")
    ap.add_argument("--bearer-file", metavar="FILE",
                    help="use a browser session token from FILE (raw token or a 'Copy as fetch' capture)")
    ap.add_argument("--browser-token", action="store_true",
                    help="use the browser session token from VCFA_BROWSER_TOKEN (variable in this file, or env)")
    ap.add_argument("--groups-only", action="store_true",
                    help="import groups only; users are created by VCFA when they sign in through the IdP")
    ap.add_argument("--only", action="append", default=[], metavar="NAME",
                    help="limit to this user/group name (repeatable), e.g. for a one-object trial")
    args = ap.parse_args()
    if not args.org:
        die("set the tenant with --org <name> or VCFA_ORG")
    with open(IMPORT_FILE, encoding="utf-8") as f:
        imp = json.load(f)

    api_token = os.environ.get("VCFA_API_TOKEN") or VCFA_API_TOKEN
    browser_token = os.environ.get("VCFA_BROWSER_TOKEN") or VCFA_BROWSER_TOKEN
    if args.browser_token or (browser_token and not args.bearer_file and not api_token):
        if not browser_token:
            die("--browser-token: set VCFA_BROWSER_TOKEN (variable in this file, or env)")
        print(f"Logging in to {VCFA_HOST} with the browser session token from VCFA_BROWSER_TOKEN ...")
        headers, session = bearer_login(None, args.org, text=browser_token)
    elif args.bearer_file:
        print(f"Logging in to {VCFA_HOST} with the browser session token from {args.bearer_file} ...")
        headers, session = bearer_login(args.bearer_file, args.org)
    elif api_token:
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

    roles = get_all("/cloudapi/1.0.0/roles", headers)
    users = get_all("/cloudapi/1.0.0/users", headers)
    groups = get_all("/cloudapi/1.0.0/groups", headers)
    print(f"VCFA has {len(roles)} roles, {len(users)} users, {len(groups)} groups")

    plan = build_plan(imp, roles, users, groups, org_ref)
    if args.groups_only:
        plan["creates"] = [c for c in plan["creates"] if c["type"] == "group"]
        plan["updates"] = [c for c in plan["updates"] if c["type"] == "group"]
    if args.only:
        wanted = {n.lower() for n in args.only}
        for g in ([] if args.groups_only else imp["groups"]):  # a group is only usable with its member users, so pull them in too
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
          f"add roles to {len(plan['updates'])} existing; project-scope bindings not handled: {plan['projectBindingsNotHandled']}")
    if plan["missingRoles"]:
        print("Roles not found in VCFA (fix ROLE_MAP in export_vra_identity.py):")
        for name, n in sorted(plan["missingRoles"].items()):
            print(f"  {name}: {n}")
    print("VCFA role names available:", sorted(r["name"] for r in roles))
    for c in plan["updates"]:
        print(f"  update {c['type']} {c['name']}: add {', '.join(c['adding'])}")

    if not args.apply:
        with open(PLAN_FILE, "w", encoding="utf-8") as f:
            json.dump(plan, f, indent=2)
        print(f"DRY RUN - nothing created. Wrote {PLAN_FILE}. Re-run with --apply to create.")
        return

    ok = fail = 0
    for c in plan["creates"]:
        status, body = post(c["path"], headers, c["body"])
        name = c["body"].get("username") or c["body"]["name"]
        if status in (200, 201):
            ok += 1
        else:
            fail += 1
            print(f"  FAILED {c['type']} {name}: {status} {json.dumps(body)[:200]}")
    print(f"Done: {ok} created, {fail} failed")
    uok = ufail = 0
    for c in plan["updates"]:
        r = s.put(f"{VCFA_HOST}{c['path']}", headers=headers, data=json.dumps(c["body"]), timeout=TIMEOUT)
        if r.status_code in (200, 201):
            uok += 1
        else:
            ufail += 1
            print(f"  FAILED update {c['type']} {c['name']}: {r.status_code} {r.text[:200]}")
    if plan["updates"]:
        print(f"Roles added on existing objects: {uok} updated, {ufail} failed")


if __name__ == "__main__":
    main()
