# vra-vcfa-user-roles-migration: vRA 8 identity to VCFA

One utility in the `kobi-vcf-utils` repo (see the root `CLAUDE.md` for repo conventions). Run every command and test below from this folder.

Exports users, groups and roles from vRA 8.x and creates the groups, plus the users whose roles are not inherited from a group, with the same roles in a VCF Automation (VCFA) VM Apps org. User-facing docs are in `HOWTO.md`; keep it in sync when options change.

**Two implementations with identical logic and file formats:** PowerShell (`*.ps1`, no dependencies, what customers get) and Python (`*.py`, needs `requests`). The PowerShell version is the primary one. When you change behavior, change both and re-run the parity check (below).

## Files

| File | Purpose |
|---|---|
| `Export-VraIdentity.ps1` | PowerShell vRA export (primary). Same outputs as the Python one |
| `Import-Vcfa.ps1` | PowerShell loader (primary). Same behavior as `load_vcfa.py` |
| `Test-Export.ps1`, `Test-Import.ps1` | PowerShell offline unit tests (own tiny assert helper, no Pester) |
| `Test-Integration.ps1` | Runs both real scripts against a mock vRA+VCFA HTTP server on localhost, export then load |
| `export_vra_identity.py` | Python vRA export. Writes `vcfa-import.json` (what the loader reads) plus `vra-export.json`, `users.json`, `groups.json` |
| `load_vcfa.py` | Loader. Reads `vcfa-import.json`, builds a plan, creates groups/users. Dry run unless Apply |
| `vro_export_identity.js` | vRO variant of the export. Untested in vRO |
| `test_export.py`, `test_load.py` | Unit tests, no network |
| `report-template.html` | One shared HTML/CSS/JS template for both report kinds (`export`, `load`). Scripts embed the report data as JSON in place of `/*REPORT_DATA*/null`. Ship it with the scripts |
| `HOWTO.md` | End-user guide (PowerShell), one short section per scenario with its command. Keep it simple; do not turn it back into a reference dump |
| `example-vcfa-import.json` | One-group sample import file (fake data) |
| `examples/` | Real sample output (export, dry run, applied; two sample HTML reports: the export and the applied load) from a made-up environment, with a README that explains each user. Regenerate by running both scripts against a mock vRA/VCFA server like the one in `Test-Integration.ps1`, then replace the temp paths and mock host in the text. Committed on purpose (see the `!examples/**` lines in this folder's `.gitignore`) |

## Commands

```
# PowerShell (all must stay green before a commit; none need installs)
powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-Export.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-Import.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-Integration.ps1
.\Export-VraIdentity.ps1 [login|users|groups|all]
.\Import-Vcfa.ps1 [-Org X] [-BrowserToken|-BearerFile F|-Provider] [-Users] [-Only NAME] [-LoginOnly] [-Apply] [-ImportFile F] [-AllowMissingRoles]

# Python
python -m unittest test_export test_load
python export_vra_identity.py [login|users|groups|all]
python load_vcfa.py [--org X] [--browser-token|--bearer-file F|--provider] [--users] [--only NAME] [--login-only] [--apply]
```

Python needs Python 3 and `requests`; PowerShell needs nothing (Windows PowerShell 5.1 or 7). Developed on Windows. Only 5.1 has been tested; the PowerShell 7 branches (`-AsHashtable`, `-SkipCertificateCheck`, `-SkipHttpErrorCheck`) are written but untested.

**Parity check** (ran clean: zero differences on the real 163-user export): run Python `build_import`/`summarize`/`trim_project` and the PowerShell `New-VcfaImport`/`Get-Summary`/`Get-TrimmedProject` over the same `vra-export.json` and diff the JSON.

## Conventions

- **HTML reports.** Each run ends with `vra-export-report.html` (export `all`) or `vcfa-load-report.html` (loader: dry run, applied, and a refused apply with mode `blocked`). Builders: `New-ExportReportData`/`build_export_report` and `New-LoadReportData`/`build_load_report`; both languages must produce the SAME JSON (keys, order of rows, wording of attention items) so one template renders both. Rows are sorted ordinally (lower-cased name) to match Python. The template builds the DOM with `textContent` only (never `innerHTML`) and the writer escapes `</` as `<\/`, so names cannot inject markup. A missing template only prints a notice. Reports hold user names: `*-report.html` is git-ignored. Tests: report data in `Test-Export.ps1`/`Test-Import.ps1`/`test_export.py`/`test_load.py`, the real files in `Test-Integration.ps1`. Preview by generating from `vra-export.json` and screenshotting with `msedge --headless=new --screenshot` (give it a timeout; it can hang).
- **PowerShell helper block.** The prompt/HTTP helpers (`Die` through `Invoke-Api`, incl. `Sort-Ordinal`) are identical copies in both `.ps1` files; change both. Scripts are dot-source safe (`Main` only runs when `$MyInvocation.InvocationName -ne '.'`) and `Die` throws, so tests can load them. Tests override functions (`Read-Line`, `Invoke-Api`, `Get-AllVcfa`, ...) after dot-sourcing; `$script:ForceInteractive` forces prompts on or off.
- **PowerShell gotchas learned the hard way** (each one bit during the port): (1) variable names are case-insensitive, so a local `$browserToken` collides with the `-BrowserToken` switch; (2) `$PSBoundParameters` inside a function is the function's, so the script computes `$script:NoFlags` at top level; (3) lists: a function that returns with `return ,$arr` must not be wrapped in `@()` by the caller (double wrapping), so list-returning helpers emit flat and callers wrap in `@()`; `Sort-Ordinal` is the one that returns an array object, call it without `@()`; (4) write `${var}://` not `$var://`; (5) keep the files ASCII-only (5.1 reads BOM-less files as ANSI); (6) 5.1 `Invoke-WebRequest` throws on 4xx, and the error body is often only in `$err.ErrorDetails.Message`; (7) decode responses as UTF-8 from `RawContentStream`, not `.Content`; (8) a string request body is sent as ISO-8859-1 by 5.1, which mangles non-ASCII names and passwords, so `Invoke-Api` sends UTF-8 bytes with `charset=utf-8`; (9) `[Array]::Sort($keys, $items, $comparer)` without explicit `[Array]`/`[IComparer]` casts sorts only the keys, so `Sort-ByKey` casts; (10) `ConvertTo-Json` pads `"key":  "value"` so never string-match JSON text.
- **Scripts stay standalone.** Each runs on its own and imports nothing from the other. The `ask()` and `choose()` prompt helpers are intentionally duplicated in both files; if you change one, change the other.
- **Hosts** go through `normalize_host`/`ask_host` (duplicated in both scripts): bare FQDN in, `https://` added when no scheme, explicit scheme kept, port kept, path/slash dropped, invalid input re-asked.
- **Every input is a prompt with an example.** `ask(label, default, secret, example)` shows `[default]` or `(e.g. example)`; `confirm()` is the yes/no helper. Each config constant has an `e.g.` comment. Only `TIMEOUT` and `API_VERSION` are not prompted. A new input must get a prompt, an example, and a test with a mocked `input`.
- **Interactive by default.** No arguments gives prompts with defaults from env vars or the config constants at the top of each file. Flags skip the matching prompt. When `sys.stdin.isatty()` is false nothing is prompted (tests and automation rely on this; tests patch `sys.stdin.isatty`).
- **Loader is safe by default.** Dry run unless `--apply` or the wizard's Apply choice, which also requires typing `yes`. Never make a write path that skips this.
- **Default load = groups + users whose roles are not inherited (user decision).** `direct_users`/`Get-DirectUsers` computes, from `roleBindings` and `groups[].members`, the users with at least one org role (compared by `norm_role`) that none of their groups gives them; users with no roles, or only group-given roles, are left to the IdP group claim. Modes: default `free`, `--groups-only` = `none`, `--users` = `all` (every user); naming a user in `--only` forces `all` for that name; `--users` with `--groups-only` is refused. The plan carries `directUsers` and `localUsersWithRoles` (local users with roles are never created, only listed). Project-only users get a synthetic org_member binding in the export, so they count as direct. The export also records `memberOf` per user (informational).
- **Projects are record-only (user decision).** Never add code that writes project membership. The export records projects and `project:*` bindings; the loader only lists them in `plan["projectBindings"]`.
- **Role names** are matched with `norm_role` (case/punctuation-insensitive, Admin == Administrator) and the loader always uses VCFA's own spelling. Bindings in the import keep the original `vraRole`.
- **Role parity.** `build_plan` records roles that do not exist in VCFA per principal (`missingByPrincipal`); `--apply` dies if any planned object is affected unless `--allow-missing-roles`. After apply `verify_roles` re-reads VCFA and compares to the plan. Project bindings are kept per project in `plan["projectBindings"]` (written to `vcfa-plan.json`, also on apply) but not loaded.
- **Browser token input.** A multi-line 'Copy as fetch' pasted into a prompt breaks (only line 1 is read, the rest answers later prompts), so the PowerShell token prompt (`Read-BrowserToken`) reads the clipboard on an empty Enter. `Get-BearerToken`/`bearer_login` accept a raw token, `Bearer <t>`, a quoted token, or a whole fetch/cURL/PowerShell capture, and refuse text with whitespace and no authorization header instead of sending it as a token. Python has no clipboard prompt; use `--bearer-file`. The real console paste of a long single-line token is untested.
- **Wizard trigger in `load_vcfa.py`:** the full wizard runs only when `len(sys.argv) == 1`. With any flag, the action is a dry run unless `--apply` or `--login-only`.
- Config that tests patch (`INCLUDE_DOMAINS`, `USERNAME`, `PASSWORD`, `OUTPUT_DIR`, `VCFA_BROWSER_TOKEN`) are module globals. `VRA_HOST` and `VCFA_HOST` are reassigned from prompts inside `main()`.
- When adding an option: add the flag/parameter and the prompt in BOTH implementations, add the scenario to `HOWTO.md`, add unit tests (Python and PowerShell). If it touches HTTP, extend `Test-Integration.ps1`.

## Domain facts worth remembering

- Only a **browser session token** can create users/groups; API tokens get 403 on create but can read.
- Group membership cannot be migrated (no VCFA API). For SSO (`OAUTH`) groups the IdP decides membership at login; the VCFA group name must match the IdP claim exactly.
- Only groups added to the vRA org with a role are exported. AD-only groups are not.
- Not migrated: project roles (loader skips `project:*` scopes and counts them), local `System Domain` users (need passwords), `migration:admin` (no VCFA role). `saltstack:` and `codestream:` roles are ignored on purpose (`IGNORE_ROLE_PREFIXES`).
- The VCFA write calls need the `x-vmware-vcloud-auth-context` and `x-vmware-vcloud-tenant-context` headers or they return 403.
- vRA project members come from `/iaas/api/projects` as bare usernames in the `email` field (no domain). `build_import` resolves them to UPNs via a directory of all users and group members, adds project-only users to `imp["users"]` with an `org_member` binding, and reports misses in `unresolvedProjectUsers`/`warnings` (optionally resolved with a default domain). The loader still does not apply `project:*` bindings.
- Existing objects are not recreated, but missing vRA roles are added. Roles are never removed.
- `ROLE_MAP` in `export_vra_identity.py` has TODO-confirmed VCFA role names; the loader's dry run prints the names VCFA really has.

## Security

This folder's `.gitignore` excludes `*.json`, `*.txt` and `*-report.html` (the repo root ignores `.claude/`), because exports hold user data and token captures hold live sessions; only `example-*.json` and `examples/` are let through. Never commit credentials or paste tokens into code, chat or logs. Use env vars or the hidden prompts.

## Status and next steps

Done: PowerShell port of both scripts with parity to Python (123 + 161 unit assertions, 46 integration assertions, all passing; Python 86 tests), HTML reports for the export and the load with parity between languages, export, loader (role sync), interactive prompts in both scripts, project-only users included in the import, default load of groups plus users whose roles are not inherited (`--groups-only`, `--users`, `--only` to change it), tolerant role-name matching with a printed role mapping, role-parity guard and post-apply check.

The self-signed HTTPS bypass on 5.1 was checked once by hand against a throwaway self-signed TLS server (verify off = 200, verify on = rejected); it is not part of `Test-Integration.ps1` because it needs a certificate in the user store.

The reports were rendered with headless Edge from the real 163-user export and checked by eye at desktop width and at 390px (inside a 390px iframe: headless Edge will not go narrower than ~500px, so a plain narrow screenshot looks cropped but is not). Dark mode is untested.

Not verified against a live system in this repo's history: anything against a real vRA or VCFA, the interactive prompts in a real console (covered by mocked input only; `Read-Host` itself is untested), PowerShell 7, and `vro_export_identity.js`.

Ideas, not started:
- Confirm and fix the `ROLE_MAP` target names against a real VCFA org.
- Test `vro_export_identity.js` inside vRO.
- Optional `--yes` flag to run the wizard unattended.
