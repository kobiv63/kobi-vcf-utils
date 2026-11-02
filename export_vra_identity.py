"""Export users, groups and roles from vRA 8.x to JSON (raw + VCFA-shaped).

Fill in USERNAME / DOMAIN below (PASSWORD is prompted if left empty), then run:
    python export_vra_identity.py
Output goes to ./output/
"""
import base64
import getpass
import json
import os
import sys
from datetime import datetime, timezone

import requests

# ---- Config -----------------------------------------------------------------
VRA_HOST = os.environ.get("VRA_HOST", "https://vra.example.com")
USERNAME = ""          # e.g. "configurationadmin"
PASSWORD = ""          # leave empty to be prompted
DOMAIN = ""  # vIDM domain the login account belongs to
# Domains to include in the export (case-insensitive). Empty list = everything.
# One admin login returns principals from all vIDM domains assigned to the org.
INCLUDE_DOMAINS = ["System Domain", "corp.example.com"]  # TODO: set your custom domain
VERIFY_TLS = False     # lab uses a self-signed cert
TIMEOUT = 30           # seconds per request
OUTPUT_DIR = os.getcwd()  # files are written directly in the folder you run the script from

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
DIRECTORY_PROVIDER_TYPE = "OAUTH"  # providerType for non-System-Domain users/groups in VCFA
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


def build_import(users, groups, projects):
    warnings, bindings = [], []

    def bind(kind, name, scope, vra_role):
        if is_ignored(vra_role):
            return
        vcfa_role = ROLE_MAP.get(vra_role)
        if vcfa_role is None:
            warnings.append(f"unmapped role '{vra_role}' for {kind} '{name}' ({scope})")
            return
        bindings.append({"principalType": kind, "principal": name, "scope": scope, "role": vcfa_role})

    for u in users:
        for role in role_names(u):
            bind("user", upn(u), "organization", role)
    for g in groups:
        for role in role_names(g):
            bind("group", principal_name(g), "organization", role)
    for proj in projects:
        for field in ("administrators", "members", "viewers", "supervisors"):
            for p in proj.get(field) or []:
                kind = "group" if p.get("type") == "group" else "user"
                bind(kind, p.get("email") or p.get("name"), f"project:{proj.get('name')}", f"project:{field}")

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
    if warnings:
        imp["warnings"] = warnings
    return imp


def dump(name, data):
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    path = os.path.join(OUTPUT_DIR, name)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
    print(f"Wrote {path}")


def main():
    # Usage: python export_vra_identity.py [login|users|groups|all]   (default: all)
    step = sys.argv[1] if len(sys.argv) > 1 else "all"
    username = USERNAME or os.environ.get("VRA_USERNAME") or input("vRA username: ")
    password = PASSWORD or os.environ.get("VRA_PASSWORD") or getpass.getpass("vRA password: ")

    print(f"Logging in to {VRA_HOST} ...")
    csp_token, iaas_token = login(username, password, os.environ.get("VRA_DOMAIN") or DOMAIN)
    org = get_org_id(csp_token)
    print(f"LOGIN OK. Org: {org}")
    if step == "login":
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
    for g in groups:
        members, status = get_all(f"{group_path}/{g['id']}/users", csp_token)
        g["members"] = [{k: x.get(k) for k in ("userId", "username", "domain", "email", "firstName", "lastName") if x.get(k)}
                        for x in members] if status == 200 else []
    print(f"  {len(groups)}/{len(all_groups)} groups in selected domains via {group_path}")
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
    imp = build_import(users, groups, projects)

    os.makedirs(OUTPUT_DIR, exist_ok=True)
    files = (
        ("vra-export.json", raw),
        ("vcfa-import.json", imp),
        ("users.json", [summarize(u) for u in users]),
        ("groups.json", [summarize(g) for g in groups]),
    )
    for name, data in files:
        path = os.path.join(OUTPUT_DIR, name)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
        print(f"Wrote {path}")
    if imp.get("warnings"):
        print(f"{len(imp['warnings'])} warnings (unmapped roles) - see vcfa-import.json")


if __name__ == "__main__":
    main()
