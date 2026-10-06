---
name: new-tool
description: Build a new field tool (python, bash or PowerShell script) in this repo following CLAUDE.md conventions. Use when asked to add, write or create a tool or script.
argument-hint: <what the tool should do> [py|sh|ps1]
---

Build a new tool that does: $ARGUMENTS

1. Re-read the hard rules and naming section of `CLAUDE.md`.
2. Check whether a tool already does this or something close (look at the README
   catalog and `tools/`). If one does, suggest extending it or adding another
   language version under the same number instead of making a new tool.
3. Choose the language, `verb-noun` name and Category. Get the next free number
   from `python3 catalog.py` (it checks `tools/` and `_retired/`). If anything is unclear
   (target OS, read vs. write, what inputs it takes), ask before writing.
4. Start from `templates/template.<ext>` and write the tool as `tools/<NNN>-<verb-noun>.<ext>`.
5. Work through the Definition of Done in `CLAUDE.md`, including running
   `python3 catalog.py`.
6. Report the file path, an example command line, and what was and wasn't tested.
