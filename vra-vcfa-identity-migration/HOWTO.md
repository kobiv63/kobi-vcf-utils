# Move vRA 8 users, groups and roles to VCFA

Two PowerShell scripts. The first reads vRA (read only) and writes an import file. The second creates the groups in VCF Automation (VCFA) with the same roles, plus any users whose roles do not come from a group. By default it only shows what it would do; nothing is created until you add `-Apply`.

**Run every command in this guide from this folder.**

**Nothing to install.** Windows PowerShell 5.1 (already on Windows) or PowerShell 7 is enough. Run both scripts from the same folder. Prefer Python? See [Python version](#python-version) at the end; it does the same thing.

| File | What it does |
|---|---|
| `Export-VraIdentity.ps1` | Reads vRA and writes `vcfa-import.json` (plus `vra-export.json`, `users.json`, `groups.json`) |
| `Import-Vcfa.ps1` | Reads an import file and creates the groups, plus the users whose roles are not inherited from a group, in VCFA |
| `Sync-IdentitySource.ps1` | Optional step 0. Makes sure the AD groups are provisioned in the VCF Operations identity source (adds missing base group DNs) |
| `report-template.html` | The look of the HTML reports. Keep it next to the scripts |
| `example-vcfa-import.json` | A tiny import file with one group, to try the loader safely |
| `HOWTO.md` | This guide |

**Both scripts ask you questions.** Run them and answer the prompts. Enter accepts the value shown in `[brackets]`. For hosts type only the name, for example `dev.vra.local`; `https://` is added for you.

**If PowerShell says scripts are disabled**, run this once in the folder, or start the script as shown:
```
Unblock-File .\*.ps1
powershell -ExecutionPolicy Bypass -File .\Export-VraIdentity.ps1 login
```

---

## 0. Optional: provision the AD groups in VCF Operations first

**Skip this if the groups were already moved to the VCF Operations identity source by hand.** VCFA only sees an AD group after VCF Operations provisions it ("directory group provisioning" in the identity source). `Sync-IdentitySource.ps1` compares the base group DNs set in IDM (Workspace ONE Access) with the ones in VCF Operations and adds the missing ones. It never removes or changes anything that is already there, and it is a dry run until you say otherwise. PowerShell only.

You need an account for IDM and one for VCF Operations. It asks for the hosts (name only, `https://` is added), usernames and passwords (hidden). If a password login does not work it falls back to a browser token (copy any request as fetch and press Enter at the token prompt).

**Check both logins (changes nothing):**
```
.\Sync-IdentitySource.ps1 login
```

**Compare IDM with VCF Operations (changes nothing):**
```
.\Sync-IdentitySource.ps1 compare
```
It lists the base DNs IDM needs, the ones VCF Operations has, and which are missing. Local IDM directories and nested groups are ignored.

**Add the missing base DNs, with a menu:**
```
.\Sync-IdentitySource.ps1
```
Pick *All* (recommended) or one base DN, then *Dry run* (default) or *Write*. A dry run prints the plan and saves the current and planned profile; nothing is sent. Write needs you to type `yes`.

**Add one base DN, or all missing, without the menu:**
```
.\Sync-IdentitySource.ps1 apply -AddBaseDn "CN=my-test-group,OU=Test,DC=corp,DC=local"
.\Sync-IdentitySource.ps1 apply -AddBaseDn "CN=my-test-group,OU=Test,DC=corp,DC=local" -Apply
.\Sync-IdentitySource.ps1 apply -AddAllMissing -Apply
```
Without `-Apply` it is a dry run. A single group is added as a chosen group; an OU or the domain root is added as "all groups under it", and the plan warns you about that. Before writing it saves `sync-profile-backup-*.json`, and afterwards it reads the profile back and prints `VERIFIED`. The groups show up after the next directory sync in VCF Operations.

If the server refuses some read-only fields or an empty attribute mapping (normally `employeeID`), the script leaves out exactly those, says so, and sends once more. Everything else still has to be a pure addition or it stops.

Settings can come from `$env:IDM_HOST`, `$env:IDM_USERNAME`, `$env:VCFOPS_HOST`, `$env:VCFOPS_USERNAME` and similar. The files it writes (`identity-sources.json`, the backups) contain directory data and are git-ignored.


---

## 1. Export from vRA

**Check the login first (changes nothing):**
```
.\Export-VraIdentity.ps1 login
```

**Export everything:**
```
.\Export-VraIdentity.ps1 all
```
It asks for the vRA host, username, password, domain and which domains to export (`all` for everything). It writes `vcfa-import.json` in the folder you choose (default: the current folder). Running it again overwrites the previous files. Users who only have project access (and are in no group) are included too; if the export cannot tell which domain one belongs to, it asks.

**Peek at the raw data (optional):**
```
.\Export-VraIdentity.ps1 users
.\Export-VraIdentity.ps1 groups
```

---

## 2. Load into VCFA

You need a browser token or an API token (see "Getting the VCFA token" below). The commands below use `-BrowserToken`; use `-ApiToken` instead to log in with an API token. Every command asks for the VCFA host and org, and for the token if you did not set one.

**Test the login only:**
```
.\Import-Vcfa.ps1 -BrowserToken -LoginOnly
```

**Try it on the example file (one group):**
```
.\Import-Vcfa.ps1 -BrowserToken -ImportFile example-vcfa-import.json
```
This is a dry run. It prints the plan and the role mapping and writes `vcfa-plan.json`. To really create it, add `-Apply`. Open `example-vcfa-import.json` first and change the group name and the `role` values to ones that exist in your org.

**Load one group from your export:**
```
.\Import-Vcfa.ps1 -BrowserToken -Only "Infra-Admins@corp.example.com"
.\Import-Vcfa.ps1 -BrowserToken -Only "Infra-Admins@corp.example.com" -Apply
```
The first line is the dry run, the second creates it. The group name must match exactly. To list the names in your export:
```
(Get-Content .\vcfa-import.json -Raw | ConvertFrom-Json).groups.name
```

**Load one user from your export:**
```
.\Import-Vcfa.ps1 -BrowserToken -Only "olga@corp.example.com" -Apply
```

**Load everything that is needed (the default): all groups, plus users whose roles are not inherited from a group:**
```
.\Import-Vcfa.ps1 -BrowserToken
.\Import-Vcfa.ps1 -BrowserToken -Apply
```
The dry run prints which users were chosen and which roles they hold that no group gives them.

**Load groups only (no users at all):**
```
.\Import-Vcfa.ps1 -BrowserToken -GroupsOnly -Apply
```

**Load every user in the file, even those with no roles:**
```
.\Import-Vcfa.ps1 -BrowserToken -Users -Apply
```

### Which users get loaded by default

A user is loaded when at least one of their roles is **not** given by a group they belong to. That covers:
- users who are in no group but have roles of their own,
- users who are in a group but also have extra roles of their own,
- users who only have project access (the export gives them the Organization Member role so they can exist).

A user is **not** loaded when they have no roles, or when everything they have comes from their groups. Those users are created by VCFA at their first sign-in and get their roles from the group. Local `System Domain` users with roles are never created (they need passwords); the dry run lists them so you can create them by hand.

**Prefer questions over parameters?** Run `.\Import-Vcfa.ps1` with no parameters and answer the prompts.

After `-Apply` the script checks VCFA and prints `Role check: N/N objects have the same org/service roles as in vRA`.

---

## The reports

Every run ends with a one-page HTML report, so you do not have to read the console output.

| File | Written by | Shows |
|---|---|---|
| `vra-export-report.html` | the export (`all`), in the output folder | what was exported, role mapping, groups, users, projects, and anything to review |
| `vcfa-load-report.html` | the loader, in the current folder | the plan (dry run) or the result (apply), including a refused apply |

Open the file in any browser (double-click it). It works offline. The `examples` folder has a sample of the outputs (console text, plan, import file, and an export report and a load report) from a small made-up environment.

- **The banner at the top says what happened:** *Dry run, nothing was changed*, *Applied successfully*, *Applied with problems*, or *Not applied*.
- **Numbers first:** groups and users to create (or created), how many failed, the role check, and how many users were not loaded.
- **"Needs your attention" comes next** and only lists real issues: roles missing in VCFA, failed requests, role differences from vRA, local users to create by hand, group member lists that could not be read.
- **Tables below** (search box on each) show every group and user with their roles, why a user was loaded, why others were not, and what was skipped. Most tables start collapsed; click a heading to open it.

The reports contain user and group names from the customer environment. Do not share them outside the engagement; `.gitignore` keeps them out of git. If `report-template.html` is missing, the scripts still work and just skip the report.

---

## Getting the VCFA token

You can log in with a **browser token** (`-BrowserToken`) or an **API token** (`-ApiToken`). Those are the only two methods.

### Browser token

Sign in to your VCFA org in the browser, open dev tools, go to the Network tab, right-click any `cloudapi` request and choose Copy, **Copy as fetch**. (Copy as cURL or as PowerShell work too.) The token expires within minutes, so run the load right away.

**Easiest: let the script read the clipboard.** Right after the copy above, run the command. At the token prompt just press **Enter** on an empty line; the script reads the copied request from the clipboard and picks the token out of it. You never paste a long multi-line text into the window.
```
.\Import-Vcfa.ps1 -BrowserToken -LoginOnly
Browser token (paste ONLY the token, or just press Enter to read it from the clipboard):   <press Enter>
```

**Do not paste the whole copied request into the prompt.** It spans many lines and PowerShell would take only the first one. If you paste, paste only the token (the long text after `Bearer `). Pasted text that is clearly not a token is refused with an explanation.

To skip the question, set the token first:
```
$env:VCFA_BROWSER_TOKEN = 'paste-the-token-here'
.\Import-Vcfa.ps1 -BrowserToken -LoginOnly
```

### API token

Create an API token in the VCFA UI, then:
```
.\Import-Vcfa.ps1 -ApiToken -LoginOnly
```
The script asks for the token (input is hidden). To skip the question:
```
$env:VCFA_API_TOKEN = 'paste-the-token-here'
.\Import-Vcfa.ps1 -ApiToken -LoginOnly
```
An API token does not expire within minutes like the browser token does, so it suits longer sessions. Treat it like a password and delete it in the VCFA UI when you are done.

If you give neither `-BrowserToken` nor `-ApiToken`, the script uses a token it finds in `VCFA_API_TOKEN` or `VCFA_BROWSER_TOKEN`; with neither set it stops and tells you what to add.

---

## Roles

- vRA roles are mapped to VCFA roles (`$script:RoleMap` at the top of `Export-VraIdentity.ps1`): Organization Owner/Member, Assembler, Service Broker, Orchestrator. The dry run prints `vRA role -> VCFA role` for every role.
- Names are matched loosely, so `Assembler Admin` finds `Assembler Administrator`.
- **Apply stops** if a needed role does not exist in VCFA, so nobody silently gets fewer roles. Fix the role map, or add `-AllowMissingRoles` to go ahead anyway.
- Objects that already exist are not recreated; roles they lack are added. Roles are never removed.

## What is not migrated

- **Projects.** Project roles are only recorded in the export (`vra-export.json`, `vcfa-import.json`). Nothing is loaded into VCFA projects.
- **Group membership.** For SSO groups the identity provider decides membership at login. The VCFA group name must match the IdP group name exactly. Users appear in VCFA at their first login and inherit the group's roles.
- **Local users** (they need passwords; the dry run lists the ones that hold roles), `migration:admin` (no VCFA role), and Saltstack/Codestream roles.
- Only groups added to the vRA org with a role are exported. AD-only groups are not.

## Parameters (`Import-Vcfa.ps1`)

| Parameter | Meaning |
|---|---|
| `-Only NAME` | Load just this group or user (several allowed: `-Only "a","b"`) |
| `-GroupsOnly` | Load groups only, no users at all |
| `-Users` | Load every user in the file (default: only users whose roles are not inherited from a group) |
| `-Apply` | Really create things (default is a dry run) |
| `-LoginOnly` | Test the login and stop |
| `-ImportFile FILE` | Read this file instead of `vcfa-import.json` |
| `-Org NAME` | VCFA org (asked if missing) |
| `-BrowserToken` | Log in with a browser token (asked if not set) |
| `-ApiToken` | Log in with an API token (asked if not set) |
| `-AllowMissingRoles` | Apply even if some roles are missing in VCFA |

Settings can also come from `$env:VCFA_HOST`, `$env:VCFA_ORG`, `$env:VRA_HOST`, `$env:VRA_USERNAME`, `$env:VRA_DOMAIN` and similar; each prompt shows its default.

## Troubleshooting

| Problem | Fix |
|---|---|
| vRA `Invalid username or password` | Wrong domain |
| VCFA `401` | Token expired; get a new one |
| `no login method` | Add `-BrowserToken` or `-ApiToken` (or set `VCFA_BROWSER_TOKEN` / `VCFA_API_TOKEN`) |
| `Roles not found in VCFA` | A role-map name does not exist in your org |
| Group has no users in VCFA | Users have not signed in yet, or the IdP group name does not match |
| `running scripts is disabled` | See the note at the top |
| Certificate errors | Answer `n` to "Verify the TLS certificate?" for a self-signed certificate |

## Security

Never commit passwords or tokens; type them at the prompts or use environment variables. The export files contain user data and are excluded by `.gitignore`. Delete token captures after use.

## Python version

The same two tools exist in Python, with identical behavior, prompts, file formats and HTML reports (they use the same `report-template.html`). Use it if you prefer Python or are not on Windows.

You need Python 3 and `pip install requests`. Run both scripts from the same folder.

| File | PowerShell equivalent |
|---|---|
| `export_vra_identity.py` | `Export-VraIdentity.ps1` |
| `load_vcfa.py` | `Import-Vcfa.ps1` |

**Export from vRA**
```
python export_vra_identity.py login
python export_vra_identity.py all
python export_vra_identity.py users
python export_vra_identity.py groups
```

**Load into VCFA** (each command asks for the VCFA host and org, and for the token if it is not set)
```
python load_vcfa.py --browser-token --login-only
python load_vcfa.py --browser-token --import-file example-vcfa-import.json
python load_vcfa.py --browser-token --only "Infra-Admins@corp.example.com"
python load_vcfa.py --browser-token --only "Infra-Admins@corp.example.com" --apply
python load_vcfa.py --browser-token --only "olga@corp.example.com" --apply
python load_vcfa.py --browser-token
python load_vcfa.py --browser-token --groups-only --apply
python load_vcfa.py --browser-token --users --apply
python load_vcfa.py
```
In order: test the login, dry run on the example file, dry run then create one group, create one user, dry run for the default load (groups plus users whose roles are not inherited from a group), create groups only, create every user, and the question wizard. As in PowerShell, nothing is created without `--apply`.

To list the group names in your export:
```
python -c "import json;print(*[g['name'] for g in json.load(open('vcfa-import.json'))['groups']],sep=chr(10))"
```

**Options**

| Python | PowerShell |
|---|---|
| `--only NAME` | `-Only NAME` |
| `--groups-only` | `-GroupsOnly` |
| `--users` | `-Users` |
| `--apply` | `-Apply` |
| `--login-only` | `-LoginOnly` |
| `--import-file FILE` | `-ImportFile FILE` |
| `--org NAME` | `-Org NAME` |
| `--browser-token` | `-BrowserToken` |
| `--api-token` | `-ApiToken` |
| `--allow-missing-roles` | `-AllowMissingRoles` |

Everything else in this guide (getting the token, roles, what is not migrated, troubleshooting) applies to both versions. Role names live in `ROLE_MAP` at the top of `export_vra_identity.py`. Settings can come from environment variables, for example `set VCFA_HOST=dev.vcfa.local` in cmd, or `$env:VCFA_HOST = 'dev.vcfa.local'` in PowerShell.

---

## For developers

`CLAUDE.md` has the project notes.

Tests, none need installs. PowerShell: `.\Test-Export.ps1` and `.\Test-Import.ps1` (offline unit tests) and `.\Test-Integration.ps1` (runs both scripts against a mock vRA and VCFA on localhost). Python: `python -m unittest test_export test_load`.
