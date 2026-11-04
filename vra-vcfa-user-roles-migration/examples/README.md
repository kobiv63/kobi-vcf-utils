# Sample output

Real output from running the scripts against a small made-up environment (`example.com` names only, nothing from a customer). Open the two `*-report.html` files in a browser to see what a run looks like: one for the export and one for the applied load.

| Folder | What it is |
|---|---|
| `export/` | `Export-VraIdentity.ps1 all`: the import file (`vcfa-import.json`), the raw export, the user and group summaries, the console output and the HTML report |
| `load-dry-run/` | `Import-Vcfa.ps1 -BrowserToken`: the plan (`vcfa-plan.json`) and the console output. Nothing was changed. A dry run also writes a report, in the same layout as the applied one |
| `load-applied/` | The same load with `-Apply`: console output and the report, with the role check |

## The made-up environment

| Who | Roles in vRA | What the loader does |
|---|---|---|
| `Infra-Admins`, `Finance-Users`, `Legacy-Admins` (groups) | org member plus service roles | Created |
| `olga` (in `Infra-Admins`) | her group's roles, plus Service Broker User | **Loaded**: one role is not inherited |
| `roy` (in `Infra-Admins`) | Organization Member only | Not loaded: everything comes from the group |
| `dana` (in no group) | Organization Owner, plus `migration:admin` | **Loaded**; `migration:admin` has no VCFA role, so it is a warning |
| `svc-backup` | none | Not loaded: nothing to preserve |
| `noam` (other domain, project access only) | none in vRA | **Loaded** with Organization Member so he can exist in VCFA |
| `admin` (System Domain, local) | Organization Owner | Never created (needs a password); listed in the report |
| `ghost` (named in a project) | not found in vRA | Warned about in the export; not imported |
| `Legacy-Admins` member list | unreadable (HTTP 403) | Warned about in the export |

The project (`Demo-Project`) is only recorded, never loaded.

These files were produced by a mock vRA and VCFA on localhost, so the hosts, the org and the ids are made up. The dates are the real run times.
