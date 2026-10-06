#!/usr/bin/env python3
"""
Rebuild the tool catalog in README.md from the header of every tool.

    python3 catalog.py           # rewrite README.md between the CATALOG markers
    python3 catalog.py --check   # exit 1 if README.md is out of date (for CI / pre-commit)

A tool's row comes from its filename (tools/<NNN>-<verb-noun>.<ext>) and the
"Synopsis:" / "Category:" / "Platform:" lines in its header (or .SYNOPSIS for
PowerShell). Files sharing an ID (002-port-check.py + .ps1) are one row.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent
TOOLS = ROOT / "tools"
RETIRED = ROOT / "_retired"
README = ROOT / "README.md"
START, END = "<!-- CATALOG:START -->", "<!-- CATALOG:END -->"

# Category value in the tool header -> README heading. Order here = order in README.
CATEGORIES = {
    "net": "Network",
    "sys": "Systems / OS",
    "ident": "Identity (AD, Entra, LDAP)",
    "sec": "Security / Audit",
    "cloud": "Cloud (Azure, AWS, M365, SaaS)",
    "util": "Utilities",
}
EXTS = {".py": "py", ".sh": "sh", ".ps1": "ps1"}
NAME_RE = re.compile(r"^(\d{3})-([a-z0-9]+(?:-[a-z0-9]+)*)$")


def header_field(lines: list, field: str) -> str:
    for i, line in enumerate(lines):
        m = re.match(rf"^\s*#?\s*{field}:\s*(.+)$", line, re.I)
        if m:
            return m.group(1).strip()
        if field.lower() == "synopsis" and line.strip().upper() == ".SYNOPSIS":
            return next((l.strip() for l in lines[i + 1:] if l.strip()), "")
    return ""


def scan() -> tuple:
    tools, problems = {}, []
    for f in sorted(TOOLS.glob("*")):
        if f.suffix not in EXTS:
            continue
        rel = f.relative_to(ROOT).as_posix()
        m = NAME_RE.match(f.stem)
        if not m:
            problems.append(f"{rel}: name must be NNN-verb-noun{f.suffix}")
            continue
        tool_id, name = m.groups()
        lines = f.read_text(errors="replace").splitlines()[:40]
        synopsis = header_field(lines, "Synopsis")
        category = header_field(lines, "Category")
        t = tools.setdefault(tool_id, {"name": name, "files": [], "synopsis": "", "category": category, "platform": set()})
        if t["name"] != name:
            problems.append(f"ID {tool_id} used for both '{t['name']}' and '{name}'")
        if category not in CATEGORIES:
            problems.append(f"{rel}: Category '{category}' must be one of: {', '.join(CATEGORIES)}")
        elif category != t["category"]:
            problems.append(f"ID {tool_id}: language versions disagree on Category")
        if synopsis.startswith("One line describing"):
            problems.append(f"{rel}: Synopsis still has the template placeholder")
        t["files"].append(f)
        t["synopsis"] = t["synopsis"] or synopsis
        plat = header_field(lines, "Platform")
        t["platform"].update(p.strip() for p in plat.split(",") if p.strip())

    for f in RETIRED.glob("*"):
        m = NAME_RE.match(f.stem)
        if m and m.group(1) in tools:
            problems.append(f"ID {m.group(1)} is retired ({f.name}) but reused in tools/")
    return tools, problems


def render(tools: dict) -> str:
    out = []
    for cat, title in CATEGORIES.items():
        rows = {k: v for k, v in tools.items() if v["category"] == cat}
        if not rows:
            continue
        out.append(f"### {title}\n")
        out.append("| ID | Tool | Lang | Platform | Description |")
        out.append("|----|------|------|----------|-------------|")
        for tool_id in sorted(rows):
            t = rows[tool_id]
            langs = " ".join(
                f"[{EXTS[f.suffix]}]({f.relative_to(ROOT).as_posix()})" for f in sorted(t["files"])
            )
            plat = ", ".join(sorted(t["platform"])) or "?"
            out.append(f"| **{tool_id}** | {t['name']} | {langs} | {plat} | {t['synopsis'] or '-'} |")
        out.append("")
    if not out:
        out.append("_No tools yet._")
    return "\n".join(out).rstrip() + "\n"


def main() -> int:
    tools, problems = scan()
    for p in dict.fromkeys(problems):  # dedupe, keep order
        print(f"[!] {p}", file=sys.stderr)

    text = README.read_text()
    pre, rest = text.split(START, 1)
    _, post = rest.split(END, 1)
    new = f"{pre}{START}\n{render(tools)}{END}{post}"

    if "--check" in sys.argv:
        if new != text or problems:
            print("[!] README catalog is stale or has problems - run: python3 catalog.py", file=sys.stderr)
            return 1
        return 0
    README.write_text(new)
    print(f"[+] catalog updated: {len(tools)} tools, next free ID: {next_id(tools):03d}")
    return 1 if problems else 0


def next_id(tools: dict) -> int:
    used = {int(k) for k in tools}
    used |= {int(m.group(1)) for f in RETIRED.glob("*") if (m := NAME_RE.match(f.stem))}
    return max(used, default=0) + 1


if __name__ == "__main__":
    sys.exit(main())
