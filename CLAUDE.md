# kobi-vcf-utils

A repo of small, independent utilities. Each one has its own folder, and the real notes live there: read that folder's `CLAUDE.md` before changing it (for example `vra-vcfa-user-roles-migration/CLAUDE.md`).

## Conventions

- **One folder per utility, on `main`.** Do not create a branch per utility. Branches are short-lived and end in a pull request.
- **A utility is self-contained.** It has its own `HOWTO.md` (short, one section per scenario), its own `CLAUDE.md`, its own tests, and its own `.gitignore` for generated files. The root `.gitignore` is for repo-wide things only (`__pycache__/`, `.claude/`), so a broad rule such as `*.json` never hides another utility's files.
- **Run a utility's commands and tests from inside its folder.** Paths in its docs are relative to that folder.
- **Never commit customer data or credentials.** Exports, token captures and reports contain real names; they are ignored. Samples are made-up data only (`example.com`).
- **Add a row to the table in `README.md`** when you add a utility.
- Prefer tools with no dependencies for things customers run (PowerShell on Windows). Keep any second implementation (for example Python) in step with the first.
