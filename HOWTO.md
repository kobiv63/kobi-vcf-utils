# kobi-vcf-utils: move vRA 8 identity to VCFA

Exports users, groups and roles from vRA 8.x and creates the groups (and optionally users) with the same roles in a VCF Automation (VCFA) VM Apps org.

Needs Python 3 and `pip install requests`. Files are written to the folder you run from.

| File | What it does |
|---|---|
| `export_vra_identity.py` | Reads vRA, writes `vcfa-import.json` plus backups (`users.json`, `groups.json`, `vra-export.json`) |
| `load_vcfa.py` | Reads `vcfa-import.json` and creates groups/users in VCFA. **Dry run unless `--apply`** |
| `vro_export_identity.js` | Optional vRO version of the export (untested in vRO) |
| `test_export.py` | Unit tests: `python -m unittest test_export` |

## Quick start

**1. Export from vRA**

```
set VRA_HOST=https://vra.example.com
set VRA_USERNAME=admin
set VRA_DOMAIN=corp.example.com
python export_vra_identity.py
```

You are asked for the password. Set `INCLUDE_DOMAINS` at the top of the script to the domains you want. Check `warnings` in `vcfa-import.json` for vRA roles with no VCFA equivalent.

**2. Get a browser token for VCFA**

Sign in to your VCFA org in the browser, open dev tools, Network tab, right-click any `cloudapi` request, Copy, **Copy as fetch**. Paste it into the `VCFA_BROWSER_TOKEN` variable in `load_vcfa.py` (or set the env var of the same name). It expires within minutes, so do step 3 right away.

**3. Dry run, then apply**

```
set VCFA_HOST=https://vcfa.example.com
python load_vcfa.py --org my-org --browser-token --groups-only
python load_vcfa.py --org my-org --browser-token --groups-only --only "My-Group@corp.example.com" --apply
```

The dry run changes nothing and writes `vcfa-plan.json`. Start with one small group (`--only`), check it in the VCFA UI, then run with `--apply` and no `--only`.

**4. Users sign in**

Users appear in VCFA at their first login through your identity provider, and inherit the group's roles.

## Options

| Option | Meaning |
|---|---|
| `--apply` | Really create things (default is a dry run) |
| `--groups-only` | Import groups only, no users (recommended) |
| `--only NAME` | Limit to one group or user (repeatable) |
| `--browser-token` | Use `VCFA_BROWSER_TOKEN` |
| `--bearer-file FILE` | Use a token saved in a file instead |
| `--org NAME` | VCFA org (or env `VCFA_ORG`) |

Without `--groups-only`, users from the export are created too, with their vRA roles. Objects that already exist are not recreated, but any vRA role they lack is added. Roles are never removed.

## Good to know

- **Group membership is not migrated.** VCFA has no API to add users to a group. For SSO (`OAUTH`) groups, the identity provider decides membership at login. The VCFA group name must match the IdP's group claim exactly.
- **Only groups that are in vRA are exported**, meaning added to the org with a role. A group that exists only in AD is not.
- **Only a browser token can create users and groups.** API tokens (tenant or provider) can read but get `403` on create.
- **Not migrated:** project roles, local users (they need passwords), and `migration:admin` (no VCFA role). Saltstack and Codestream roles are ignored on purpose; see `IGNORE_ROLE_PREFIXES`.
- Role names are in `ROLE_MAP` in `export_vra_identity.py`. Edit them to match your VCFA roles; the dry run prints the names VCFA has.

## Troubleshooting

| Problem | Fix |
|---|---|
| vRA `Invalid username or password` | Wrong `VRA_DOMAIN` |
| VCFA `401` | Token expired; get a new one |
| VCFA `403` on create | You used an API token; use the browser token |
| `Roles not found in VCFA` | A `ROLE_MAP` name does not exist in your org |
| Group has no users in VCFA | Users have not signed in yet, or the IdP claim does not match the group name |

## Security

Never commit credentials. Leave the password and token variables empty in the scripts and use env vars. `.gitignore` excludes `*.json` and `*.txt`, because the exports contain user data and the token captures contain live session tokens. Delete captures after use and rotate anything that was pasted into a chat or log.
