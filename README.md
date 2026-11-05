# kobi-vcf-utils

Small utilities for VMware Cloud Foundation work. Each utility lives in its own folder with its own guide, tests and notes.

| Utility | What it does | Start here |
|---|---|---|
| [`vra-vcfa-identity-migration`](vra-vcfa-identity-migration/) | Moves users, groups and roles from vRA 8 to VCF Automation (VCFA). Read-only export, safe dry run before anything is created, HTML reports. Optional first step: `Sync-IdentitySource.ps1` adds missing AD base group DNs from IDM to the VCF Operations identity source. PowerShell (no installs) and Python | [HOWTO](vra-vcfa-identity-migration/HOWTO.md) |

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

## Adding a utility

Create a new folder at the top level named after what it does (`<source>-<target>-<what>`, lower case, hyphens). Give it a `HOWTO.md`, tests, and a `.gitignore` for anything it generates that should not be committed. Add a row to the table above. Work happens on short-lived branches and merges to `main` through a pull request; there is no long-lived branch per utility.
