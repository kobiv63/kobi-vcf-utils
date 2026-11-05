# kobi-vcf-utils

Small utilities for VMware Cloud Foundation work. Each utility lives in its own folder with its own guide, tests and notes.

| Utility | What it does | Start here |
|---|---|---|
| [`vra-vcfa-identity-migration`](vra-vcfa-identity-migration/) | Moves users, groups and roles from vRA 8 to VCF Automation (VCFA). Read-only export, safe dry run before anything is created, HTML reports. Optional first step: `Sync-IdentitySource.ps1` adds missing AD base group DNs from IDM to the VCF Operations identity source. PowerShell (no installs) and Python | [HOWTO](vra-vcfa-identity-migration/HOWTO.md) |

## vra-vcfa-identity-migration: main files and how to run

Moves identities from vRA 8.x to a VCF Automation (VCFA) org. Every script comes in two versions with the same logic and file formats: **PowerShell** (primary, nothing to install, Windows PowerShell 5.1 or 7) and **Python** (needs Python 3 and `requests`). Run all commands from inside `vra-vcfa-identity-migration\`.

Typical order: optional `Sync-IdentitySource.ps1` (AD base group DNs into the VCF Operations identity source), then the export from vRA, then the load into VCFA. The load is a dry run until you add `-Apply` (`--apply`).

### Main files

| File | What it is |
|---|---|
| `Export-VraIdentity.ps1` / `export_vra_identity.py` | Read-only export from vRA 8. Writes `vcfa-import.json` (the file the loader reads), plus `vra-export.json`, `users.json`, `groups.json` and `vra-export-report.html` |
| `Import-Vcfa.ps1` / `load_vcfa.py` | Loader. Creates the groups, and the users whose roles are not inherited from a group, in a VCFA org. Writes `vcfa-plan.json` and `vcfa-load-report.html` |
| `Sync-IdentitySource.ps1` | PowerShell only, optional first step. Reads the group base DNs from Workspace ONE Access (IDM) and VCF Operations. Its only write adds one base DN to VCF Operations, and only after a typed `yes`. Still in progress |
| `vro_export_identity.js` | vRO variant of the export. Not tested in vRO yet |
| `report-template.html` | Template for both HTML reports. Keep it next to the scripts |
| `HOWTO.md` | End-user guide, one section per scenario (start here) |
| `Test-*.ps1`, `test_*.py` | Offline unit tests. `Test-Integration.ps1` runs both PowerShell scripts against a mock vRA and VCFA on localhost |
| `example-vcfa-import.json`, `examples/` | Made-up sample input, and sample output and reports from a fake environment |
| `CLAUDE.md` | Developer notes: design decisions, safety rules, parity rules |

Generated files (`*.json`, `*.txt`, `*-report.html`) hold real user names and live tokens. They are git-ignored; never commit them.

### How to run

Before you start: a vRA 8.x admin login to export, and a browser session token or API token for the VCFA org to load (see `HOWTO.md`, "Getting the VCFA token").

**PowerShell** (add `-ExecutionPolicy Bypass` if the policy blocks the script):
```
.\Export-VraIdentity.ps1 login                 # check the vRA login only
.\Export-VraIdentity.ps1 all                   # export everything; asks for host, user, password, domains
.\Import-Vcfa.ps1 -BrowserToken -LoginOnly     # check the VCFA login only
.\Import-Vcfa.ps1 -BrowserToken                # dry run: prints the plan, writes vcfa-plan.json, changes nothing
.\Import-Vcfa.ps1 -BrowserToken -Apply         # create the groups and users
.\Sync-IdentitySource.ps1 login                # then: extract, compare (read only); apply is the write step
```
Running `.\Import-Vcfa.ps1` with no parameters starts the interactive prompts. The parameters are listed in `HOWTO.md` ("Parameters").

**Python** (Python 3 with `requests` installed: `pip install requests`):
```
python export_vra_identity.py all              # or: login, users, groups
python load_vcfa.py                            # no arguments: interactive prompts
python load_vcfa.py --browser-token            # dry run
python load_vcfa.py --browser-token --apply    # create the groups and users
```

**Tests** (none need installs; run from this folder):
```
powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-Export.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-Import.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-Integration.ps1
python -m unittest test_export test_load
```

When you change behavior, change the PowerShell and Python versions together and re-run the tests.

## Layout

```
kobi-vcf-utils/
  README.md                  this file
  CLAUDE.md                  conventions for working in this repo
  <utility-name>/            one folder per utility
    HOWTO.md                 how to use it (short, one section per scenario)
    CLAUDE.md                project notes for whoever continues the work
    ...                      scripts, tests, examples
```

