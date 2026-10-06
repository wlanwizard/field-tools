# field-tools: instructions for Claude Code

This repo holds small, one-shot sysadmin and network engineering tools (Python,
bash, PowerShell). It gets downloaded onto **customer-owned laptops**, run, and
deleted. Every rule below comes from that: we're guests on someone else's machine.

The repo grows one tool at a time. When asked to build or change a tool, follow
this file. Don't add frameworks, shared libraries, or build steps. **Each tool
is one self-contained file** that still works when copied out of the repo by itself.

## Hard rules

1. **Nothing to install.**
   - Python: stdlib only, Python 3.8+. No `pip install`, no `requirements.txt`.
   - PowerShell: built-in cmdlets and .NET only. Target **Windows PowerShell 5.1**
     (the version that ships with Windows), and keep it working on PowerShell 7.
     No `Install-Module`. If a tool needs a module that ships with a Windows role
     (ActiveDirectory, DhcpServer, DnsServer), check for it and exit with a clear
     message if it's missing.
   - bash: **bash 3.2** (macOS default). No associative arrays, `mapfile`, `${var,,}`,
     or GNU-only flags. If a command differs between macOS and Linux (`sed -i`,
     `date`, `ip` vs `ifconfig`), detect it and handle both.
2. **Read-only by default.** Anything that changes state (config, files outside
   `output/`, services, AD objects) needs an explicit opt-in flag (`--apply` / `-Apply`).
   Without it, show what would change. PowerShell tools that change things use
   `SupportsShouldProcess` so `-WhatIf` works.
3. **No secrets, no customer data in the repo.** Prompt for credentials at runtime
   (`getpass`, `Get-Credential`, `read -s`) or read them from an env var. Never hard-code
   them, and never write them to output files. Examples use RFC 5737 / RFC 1918
   addresses and `example.com`.
4. **No personally identifying information, ever.** This repo is public. Nothing that
   identifies the maintainer, a customer, or anyone else goes into a file, a commit
   message, a branch name, or test data. That includes:
   - names, email addresses, phone numbers, usernames (the GitHub handle in clone
     URLs is the only exception)
   - customer or employer names, site names, project or engagement codes
   - hostnames, machine names, home-directory paths (`/Users/...`, `C:\Users\...`)
   - real IP addresses, MAC addresses, serial numbers, SSIDs, domain names
   - output pasted from a real run. Rewrite it with placeholder values first.

   Use placeholders like `acme`, `host01`, `user1`, `192.0.2.10`, `example.com`.
   Before every commit, scan the staged diff (`git diff --cached`) for anything on
   this list and stop to ask if something looks real. Commits must use the GitHub
   noreply identity configured in the repo. Never change `user.name` / `user.email`.
5. **No phoning home.** A tool only talks to the targets the user gives it. No
   telemetry, no update checks, no downloading code at runtime.
6. **Don't send anything harmful to the network.** Default to a modest rate and
   concurrency for scans and sweeps. Make them adjustable with a flag.

## Naming and placement

```
tools/<NNN>-<verb-noun>.<ext>      e.g. tools/004-dhcp-scope-usage.ps1
```

- **All tools go in `tools/`**, with no subfolders. The number is how people find a tool
  (`ls 004*`), so it comes first.
- **NNN**: one 3-digit sequence for the whole repo. Use the next free number, which
  `python3 catalog.py` prints (it checks both `tools/` and `_retired/`). Numbers are
  never reused or renumbered.
- **Same tool, another language** = same number and name, different extension
  (`001-port-check.py` + `001-port-check.ps1`). Both versions take the same inputs
  and produce the same output columns.
- **verb-noun**: lowercase and hyphenated, describing what the tool does (`port-check`,
  `ad-stale-computers`, `wlan-profile-export`).
- **Category**: a `Category:` header line (`net`, `sys`, `ident`, `sec`, `cloud`,
  `util`). It only decides which README section the tool is listed in. The list
  lives in `CATEGORIES` in `catalog.py`. Ask before adding a category, and if one is
  added, also add it to the category table in `README.md`.

**Choosing the language:** use the user's choice if they gave one. Otherwise:
Windows-only work (AD, DHCP/DNS server, registry, event logs) → `.ps1`. macOS/Linux
host work → `.sh`. Cross-platform network or API work → `.py`.

## File structure

Start from the matching file in `templates/` and keep its structure:

- **Header** (`catalog.py` reads it): `Synopsis:` (one line, appears in the README),
  `Category:`, `Platform:` (`any` or a comma list of `win`, `mac`, `linux`), `Requires:`, `Usage:`.
  PowerShell puts the synopsis under `.SYNOPSIS` and `Category`/`Platform`/`Requires` under `.NOTES`.
- **Help**: `--help` / `-h` / `Get-Help` must work and show at least one realistic example.
- **Output**: readable table on screen by default. A `--out` / `-o` / `-Out` flag also
  writes `output/<NNN>_<hostname>_<yyyymmdd-HHmmss>.<ext>` at the repo root
  (CSV for tabular data, otherwise txt or json).
- **Exit codes**: `0` = all good. `1` = ran fine but found failures or problems
  (closed ports, stale accounts). `2` = bad arguments or the tool couldn't run.
- **Errors**: clear one-line messages, no stack traces for expected failures (DNS fails,
  access denied, a module is missing). A failure on one target doesn't stop the
  run for the others.
- Keep tools short and readable. Someone may need to read one on a customer's screen
  before running it. Comment the *why*, not the *what*.

## Definition of done

1. File named correctly and placed in `tools/`, header filled in (no template placeholder text left).
2. Run it locally wherever possible (this Mac has python3 and bash; no pwsh).
   Test `--help`, a normal run, and a failure case. If the tool can't run here
   (Windows-only or needs a real target), say plainly what wasn't tested.
3. `bash -n` for shell scripts and `python3 -m py_compile` for Python.
4. `chmod +x` on `.py` and `.sh`.
5. `python3 catalog.py` exits 0 and the README catalog shows the tool.
6. Don't commit unless asked.

## Changing or retiring tools

- Fix a tool in place. If a change breaks existing flags or output columns, call it out.
- To retire a tool, `git mv` it into `_retired/` (same filename) and rerun `catalog.py`.
  Its number stays taken.

## Repo files

| Path | Purpose |
|------|---------|
| `README.md` | For the engineer in the field: how to download, how to run, and the catalog. The section between the CATALOG markers is generated, don't edit it by hand. |
| `catalog.py` | Rebuilds the README catalog from tool headers and flags naming problems. `--check` exits 1 if the README is out of date. |
| `templates/` | Reference structure for each language. Not runnable tools. |
| `output/` | Results from runs. Git-ignored. |
| `docs/REPO-SETUP.md` | Creating the GitHub repo, and the deploy-key steps for customer laptops. |
| `_retired/` | Old tools, kept so their numbers stay taken. |
