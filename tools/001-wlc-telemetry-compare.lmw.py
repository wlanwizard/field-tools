#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.8"
# dependencies = []
# ///
# Synopsis: Diff a working vs broken Catalyst 9800 show tech to find why Catalyst Center telemetry fails
# Category: net
# Requires: uv (preferred) or python3 3.8+; stdlib only, offline, reads two text files
# Usage:    uv run 001-wlc-telemetry-compare.lmw.py WORKING.txt BROKEN.txt [--full] [--out] [--save report.html]
"""
Compare two Catalyst 9800 'show tech wireless' outputs (one with working
Catalyst Center telemetry, one broken) and highlight config/state differences
that commonly break WLC -> Catalyst Center Assurance telemetry.

Usage:
    uv run 001-wlc-telemetry-compare.lmw.py WORKING.txt BROKEN.txt
    uv run 001-wlc-telemetry-compare.lmw.py WORKING.txt BROKEN.txt --full       # also full running-config diff
    uv run 001-wlc-telemetry-compare.lmw.py WORKING.txt BROKEN.txt --out        # save report to ./output/
    uv run 001-wlc-telemetry-compare.lmw.py WORKING.txt BROKEN.txt --save report.html
    ./001-wlc-telemetry-compare.lmw.py WORKING.txt BROKEN.txt                  # mac/linux, via the uv shebang

No uv on the machine? 'python3 001-wlc-telemetry-compare.lmw.py ...' works the same.

Each input can be a full 'show tech wireless' or just a 'show running-config'.
Read-only and offline: nothing connects to the WLCs.
"""
from __future__ import annotations

import argparse
import difflib
import html
import os
import re
import shutil
import socket
import sys
import textwrap
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

TOOL_ID = Path(__file__).stem.split("-")[0]
OUTPUT_DIR = Path(__file__).resolve().parent.parent / "output"


# --------------------------------------------------------------------------
# Console output (stdlib stand-in for rich: colours, rules, panels, tables,
# and a recording that can be saved as text or HTML)
# --------------------------------------------------------------------------
STYLES = ("bold", "dim", "red", "green", "yellow", "cyan")
ANSI = {"bold": "1", "dim": "2", "red": "31", "green": "32", "yellow": "33", "cyan": "36"}
CSS = {"bold": "font-weight:bold", "dim": "opacity:.6", "red": "color:#c0392b",
       "green": "color:#1e8449", "yellow": "color:#b7950b", "cyan": "color:#148f9b"}
_W = "|".join(STYLES)
# Only recognised style tags are markup; anything else in brackets is literal text
TAG_RE = re.compile(rf"\[(?:/(?:{_W})?|(?:{_W})(?: (?:{_W}))*)\]")


def parse_markup(text: str) -> list[tuple[str, str]]:
    """'[bold red]x[/] y' -> [('x', 'bold red'), (' y', '')]"""
    segs, stack, pos = [], [], 0
    for m in TAG_RE.finditer(text):
        if m.start() > pos:
            segs.append((text[pos:m.start()], " ".join(stack)))
        tag = m.group(0)[1:-1]
        if tag.startswith("/"):
            if stack:
                stack.pop()
        else:
            stack.append(tag)
        pos = m.end()
    if pos < len(text):
        segs.append((text[pos:], " ".join(stack)))
    return segs


def visible_len(segs: list[tuple[str, str]]) -> int:
    return sum(len(t) for t, _ in segs)


class Console:
    def __init__(self) -> None:
        self.lines: list[list[tuple[str, str]]] = []
        self.width = min(shutil.get_terminal_size((120, 24)).columns, 200)
        self.color = sys.stdout.isatty() and "NO_COLOR" not in os.environ
        if self.color and os.name == "nt":
            os.system("")  # turns on ANSI escape handling in the Windows console
        if hasattr(sys.stdout, "reconfigure"):
            sys.stdout.reconfigure(errors="replace")

    def _emit(self, line: list[tuple[str, str]]) -> None:
        self.lines.append(line)
        if self.color:
            print("".join(f"\033[{';'.join(ANSI[w] for w in s.split())}m{t}\033[0m" if s else t
                          for t, s in line))
        else:
            print("".join(t for t, _ in line))

    def print(self, text: str = "", style: str | None = None, markup: bool = True, **_) -> None:
        segs = parse_markup(text) if markup else [(text, "")]
        if style:
            segs = [(t, f"{style} {s}".strip()) for t, s in segs]
        line: list[tuple[str, str]] = []
        for t, s in segs:
            for i, part in enumerate(t.split("\n")):
                if i:
                    self._emit(line)
                    line = []
                if part:
                    line.append((part, s))
        self._emit(line)

    def rule(self, title: str = "") -> None:
        segs = parse_markup(title)
        fill = max(3, self.width - visible_len(segs) - 4)
        self._emit([("-- ", "dim")] + segs + [(" " + "-" * fill, "dim")])

    def panel(self, text: str, title: str = "", style: str | None = None) -> None:
        self._emit([("== ", "bold")] + parse_markup(title) + [(" " + "=" * max(3, self.width - len(title) - 4), "bold")]
                   if title else [("=" * self.width, "bold")])
        self.print(text, style=style)
        self._emit([("=" * self.width, "bold")])

    def table(self, title: str, headers: list[str], rows: list[list[str]]) -> None:
        """Every column but the last is markup; the last is plain text, wrapped to fit."""
        n = len(headers)
        cells = [[parse_markup(c) for c in r[:-1]] for r in rows]
        widths = [max([len(headers[i])] + [visible_len(c[i]) for c in cells]) for i in range(n - 1)]
        gap = "  "
        last_w = max(30, self.width - sum(widths) - len(gap) * (n - 1))
        self.rule(f"[bold]{title}[/]")
        self._emit([(gap.join(h.ljust(w) for h, w in zip(headers, widths + [0])), "bold")])
        self._emit([(gap.join("-" * w for w in widths + [min(last_w, 40)]), "dim")])
        indent = " " * (sum(widths) + len(gap) * (n - 1))
        for c, r in zip(cells, rows):
            line: list[tuple[str, str]] = []
            for segs, w in zip(c, widths):
                line += segs + [(" " * (w - visible_len(segs)) + gap, "")]
            wrapped = textwrap.wrap(r[-1], last_w) or [""]
            self._emit(line + [(wrapped[0], "")])
            for more in wrapped[1:]:
                self._emit([(indent + more, "")])

    def save_text(self, path: str) -> None:
        Path(path).write_text("\n".join("".join(t for t, _ in ln) for ln in self.lines) + "\n",
                              encoding="utf-8")

    def save_html(self, path: str) -> None:
        def span(t: str, s: str) -> str:
            t = html.escape(t)
            return f'<span style="{";".join(CSS[w] for w in s.split())}">{t}</span>' if s else t
        body = "\n".join("".join(span(t, s) for t, s in ln) for ln in self.lines)
        Path(path).write_text(
            "<!doctype html><html><head><meta charset='utf-8'><title>9800 telemetry compare</title>"
            "</head><body><pre style='font-family:Menlo,Consolas,monospace;font-size:13px'>\n"
            f"{body}\n</pre></body></html>\n", encoding="utf-8")


console = Console()

# --------------------------------------------------------------------------
# Parsing
# --------------------------------------------------------------------------
SECTION_RE = re.compile(r"^-{5,}\s*(show\s.+?)\s*-{5,}\s*$")
HEX_LINE_RE = re.compile(r"^\s+[0-9A-Fa-f]{8}(\s+[0-9A-Fa-f]{2,8})*\s*$")

# Top-level config lines relevant to Catalyst Center controllability/telemetry
RELEVANT_PATTERNS = {
    "PKI trustpoints":          r"^crypto pki trustpoint ",
    "PKI certificate chains":   r"^crypto pki certificate chain ",
    "PKI misc":                 r"^crypto pki (?!trustpoint|certificate chain)",
    "Telemetry":                r"^telemetry ",
    "Network Assurance":        r"^network-assurance",
    "NETCONF/RESTCONF":         r"^(netconf|netconf-yang|restconf)",
    "AAA":                      r"^aaa ",
    "Local users":              r"^username ",
    "HTTP/HTTPS":               r"^ip http",
    "SSH":                      r"^ip ssh",
    "SNMP":                     r"^snmp-server",
    "Syslog":                   r"^logging ",
    "NTP/Clock":                r"^(ntp |clock )",
    "DNS/Domain":               r"^ip (domain|name-server|host )",
    "Routing":                  r"^ip route ",
    "VRF":                      r"^vrf definition",
    "ACLs":                     r"^ip access-list",
    "VTY lines":                r"^line vty",
    "Wireless mgmt":            r"^wireless management",
    "Device tracking (IPDT)":   r"^device-tracking",
}


@dataclass
class Device:
    path: Path
    sections: dict[str, str] = field(default_factory=dict)
    config: dict[str, list[str]] = field(default_factory=dict)
    hostname: str = "?"

    @property
    def label(self) -> str:
        return f"{self.hostname} ({self.path.name})"


def split_sections(text: str) -> dict[str, str]:
    sections: dict[str, list[str]] = {}
    current = None
    for line in text.splitlines():
        m = SECTION_RE.match(line)
        if m:
            current = re.sub(r"\s+", " ", m.group(1).strip())
            sections.setdefault(current, [])
            continue
        if current:
            sections[current].append(line)
    return {k: "\n".join(v) for k, v in sections.items()}


def find_section(sections: dict[str, str], *prefixes: str) -> str:
    for p in prefixes:
        for k, v in sections.items():
            if k.lower() == p.lower():
                return v
    for p in prefixes:
        for k, v in sections.items():
            if k.lower().startswith(p.lower()):
                return v
    return ""


def extract_running_config(text: str, sections: dict[str, str]) -> str:
    cfg = find_section(sections, "show running-config")
    if cfg:
        return cfg
    # Fallback: plain running-config file or show tech without standard headers
    m = re.search(r"(Building configuration\.\.\..*?^end\s*$)", text, re.S | re.M)
    if m:
        return m.group(1)
    return text


def parse_config(cfg_text: str) -> dict[str, list[str]]:
    """Top-level line -> list of child lines. Cert hex blobs are dropped."""
    blocks: dict[str, list[str]] = {}
    current = None
    for raw in cfg_text.splitlines():
        line = raw.rstrip()
        if not line or line.strip() == "!" or line.startswith("Building configuration") \
                or line.startswith("Current configuration"):
            if line.strip() == "!":
                current = None
            continue
        if not line.startswith(" "):
            current = line.strip()
            blocks.setdefault(current, [])
            continue
        if current is None:
            continue
        stripped = line.strip()
        # Drop certificate hex and 'quit' lines; keep 'certificate <serial>' lines
        if HEX_LINE_RE.match(line) or stripped == "quit":
            continue
        blocks[current].append(stripped)
    return blocks


def load(path: Path) -> Device:
    text = path.read_text(encoding="utf-8", errors="replace")
    dev = Device(path=path)
    dev.sections = split_sections(text)
    dev.config = parse_config(extract_running_config(text, dev.sections))
    for k in dev.config:
        if k.startswith("hostname "):
            dev.hostname = k.split(None, 1)[1]
            break
    return dev


# --------------------------------------------------------------------------
# Helpers to read specific facts
# --------------------------------------------------------------------------
def blocks_matching(dev: Device, pattern: str) -> dict[str, list[str]]:
    rx = re.compile(pattern)
    return {k: v for k, v in dev.config.items() if rx.match(k)}


def telemetry_subs(dev: Device) -> dict[str, list[str]]:
    return blocks_matching(dev, r"^telemetry ietf subscription ")


def receivers(dev: Device) -> set[str]:
    out = set()
    for children in telemetry_subs(dev).values():
        for c in children:
            if c.startswith("receiver "):
                out.add(c)
    return out


def receiver_ips(dev: Device) -> set[str]:
    ips = set()
    for r in receivers(dev):
        m = re.search(r"ip address (\S+)", r)
        if m:
            ips.add(m.group(1))
    return ips


def source_addresses(dev: Device) -> set[str]:
    out = set()
    for children in telemetry_subs(dev).values():
        for c in children:
            if c.startswith("source-address "):
                out.add(c.split()[1])
    return out


def source_vrfs(dev: Device) -> set[str]:
    out = set()
    for children in telemetry_subs(dev).values():
        for c in children:
            if c.startswith("source-vrf "):
                out.add(c.split()[1])
    return out


def interface_ips(dev: Device) -> dict[str, str]:
    """ip -> interface name"""
    out = {}
    for k, children in blocks_matching(dev, r"^interface ").items():
        for c in children:
            m = re.match(r"ip address (\d+\.\d+\.\d+\.\d+)", c)
            if m:
                out[m.group(1)] = k.split(None, 1)[1]
            m6 = re.match(r"ipv6 address ([0-9A-Fa-f:]+)", c)
            if m6:
                out[m6.group(1).lower()] = k.split(None, 1)[1]
    return out


def na_url_ip(dev: Device) -> str | None:
    for k in dev.config:
        m = re.match(r"network-assurance url https?://\[?([^\]/\s]+)", k)
        if m:
            return m.group(1)
    return None


def cert_serials(dev: Device, chain: str) -> list[str]:
    return [c for c in dev.config.get(f"crypto pki certificate chain {chain}", [])
            if c.startswith("certificate")]


DATE_RE = re.compile(
    r"(\d{1,2}:\d{2}:\d{2})(?:\.\d+)?\s+\S+\s+(?:\w{3}\s+)?(\w{3})\s+(\d{1,2})\s+(\d{4})")


def parse_ios_date(s: str) -> datetime | None:
    m = DATE_RE.search(s)
    if not m:
        return None
    try:
        return datetime.strptime(f"{m.group(1)} {m.group(2)} {m.group(3)} {m.group(4)}",
                                 "%H:%M:%S %b %d %Y")
    except ValueError:
        return None


def device_clock(dev: Device) -> tuple[datetime | None, bool | None, str]:
    raw = find_section(dev.sections, "show clock").strip()
    if not raw:
        return None, None, ""
    line = raw.splitlines()[0].strip()
    authoritative = not line.startswith("*")  # leading * = time not synced
    return parse_ios_date(line), authoritative, line


@dataclass
class Cert:
    kind: str
    serial: str = ""
    status: str = ""
    subject: str = ""
    start: datetime | None = None
    end: datetime | None = None
    trustpoints: str = ""


def parse_pki_certs(dev: Device) -> list[Cert]:
    raw = find_section(dev.sections, "show crypto pki certificates verbose",
                       "show crypto pki certificates")
    certs: list[Cert] = []
    cur: Cert | None = None
    in_subject = False
    for line in raw.splitlines():
        if re.match(r"^(CA |Router Self-Signed |)Certificate\s*$", line.strip()) and not line.startswith(" "):
            cur = Cert(kind=line.strip())
            certs.append(cur)
            in_subject = False
            continue
        if cur is None:
            continue
        s = line.strip()
        if s.startswith("Status:"):
            cur.status = s.split(":", 1)[1].strip()
        elif s.startswith("Certificate Serial Number (hex):"):
            cur.serial = s.split(":", 1)[1].strip()
        elif s == "Subject:":
            in_subject = True
        elif in_subject and s.lower().startswith("cn="):
            cur.subject = s
            in_subject = False
        elif s.startswith("start date:"):
            cur.start = parse_ios_date(s)
        elif s.startswith("end") and "date:" in s:
            cur.end = parse_ios_date(s)
        elif s.startswith("Associated Trustpoints:"):
            cur.trustpoints = s.split(":", 1)[1].strip()
    return certs


# --------------------------------------------------------------------------
# Health checks
# --------------------------------------------------------------------------
PASS, FAIL, WARN, INFO = "PASS", "FAIL", "WARN", "INFO"


def run_checks(dev: Device, ref: Device | None = None) -> list[tuple[str, str, str]]:
    r: list[tuple[str, str, str]] = []
    cfg = dev.config

    # Trustpoints & cert chains
    for tp in ("sdn-network-infra-iwan", "DNAC-CA"):
        present = f"crypto pki trustpoint {tp}" in cfg
        r.append((f"Trustpoint {tp}", PASS if present else FAIL,
                  "present" if present else "missing (Catalyst Center did not push PKI config)"))
        serials = cert_serials(dev, tp)
        r.append((f"Cert chain {tp}", PASS if serials else FAIL,
                  ", ".join(serials) if serials else "no certificates installed"))

    # DNAC-CA should be identical across WLCs managed by the same Catalyst Center
    if ref is not None:
        a, b = cert_serials(ref, "DNAC-CA"), cert_serials(dev, "DNAC-CA")
        if a and b:
            r.append(("DNAC-CA matches working WLC", PASS if a == b else FAIL,
                      "same CA" if a == b else f"working={a} this={b} (different/renewed CC cert?)"))
        a = [s for s in cert_serials(ref, "sdn-network-infra-iwan") if s.startswith("certificate ca")]
        b = [s for s in cert_serials(dev, "sdn-network-infra-iwan") if s.startswith("certificate ca")]
        if a and b:
            r.append(("sdn-network-infra-iwan issuing CA matches", PASS if a == b else FAIL,
                      "same issuing CA" if a == b else f"working={a} this={b}"))

    # Telemetry subscriptions
    subs = telemetry_subs(dev)
    r.append(("Telemetry subscriptions", PASS if subs else FAIL, f"{len(subs)} configured"))
    if ref is not None:
        missing = sorted(set(telemetry_subs(ref)) - set(subs), key=_natkey)
        if missing:
            r.append(("Subscriptions missing vs working", FAIL,
                      ", ".join(m.split()[-1] for m in missing)))

    rcv = receivers(dev)
    if rcv:
        bad_profile = [x for x in rcv if "profile" in x and "sdn-network-infra-iwan" not in x]
        r.append(("Receiver TLS profile", FAIL if bad_profile else PASS,
                  "; ".join(sorted(rcv))))
    rips = receiver_ips(dev)
    if ref is not None and rips and receiver_ips(ref) and rips != receiver_ips(ref):
        r.append(("Receiver IP matches working WLC", FAIL,
                  f"working={sorted(receiver_ips(ref))} this={sorted(rips)}"))

    # Source address must exist on a local interface
    if_ips = interface_ips(dev)
    for sa in sorted(source_addresses(dev)):
        ok = sa.lower() in if_ips
        r.append((f"Telemetry source-address {sa}", PASS if ok else FAIL,
                  f"on {if_ips[sa.lower()]}" if ok else "not configured on any interface (IP changed?)"))
    if len(source_addresses(dev)) > 1:
        r.append(("Telemetry source-address consistency", WARN,
                  f"multiple source addresses: {sorted(source_addresses(dev))}"))
    if ref is not None and source_vrfs(ref) != source_vrfs(dev):
        r.append(("Telemetry source-vrf", WARN,
                  f"working={sorted(source_vrfs(ref)) or 'global'} this={sorted(source_vrfs(dev)) or 'global'}"))

    # Network assurance
    na_on = "network-assurance enable" in cfg
    r.append(("network-assurance enable", PASS if na_on else FAIL, "" if na_on else "missing"))
    nip = na_url_ip(dev)
    if nip and rips and nip not in rips:
        r.append(("NA URL vs telemetry receiver", WARN,
                  f"network-assurance url={nip}, receivers={sorted(rips)}"))
    na_sum = find_section(dev.sections, "show network-assurance summary")
    m = re.search(r"Network-Assurance\s*:\s*(\S+)", na_sum)
    if m:
        r.append(("Network-Assurance state", PASS if m.group(1).lower().startswith("enab") else FAIL,
                  m.group(1)))

    # NETCONF + AAA (needed for Catalyst Center management of 9800)
    nc = "netconf-yang" in cfg
    r.append(("netconf-yang", PASS if nc else FAIL, "" if nc else "missing (NETCONF mandatory for 9800)"))
    r.append(("aaa new-model", PASS if "aaa new-model" in cfg else FAIL, ""))
    authz = [k for k in cfg if k.startswith("aaa authorization exec default")]
    r.append(("aaa authorization exec default", PASS if authz else FAIL,
              authz[0] if authz else "missing (NETCONF login will fail authorization)"))

    # Clock / NTP
    ntp = [k for k in cfg if k.startswith("ntp server")]
    r.append(("NTP servers", PASS if ntp else WARN, ", ".join(ntp) or "none configured"))
    now, authoritative, clk_line = device_clock(dev)
    if clk_line:
        r.append(("Clock synced", PASS if authoritative else WARN,
                  clk_line + ("" if authoritative else "  (leading * = not authoritative)")))

    # Certificate validity vs device clock
    for c in parse_pki_certs(dev):
        if not any(t in c.trustpoints for t in ("sdn-network-infra-iwan", "DNAC-CA")):
            continue
        label = f"Cert {c.serial or '?'} [{c.trustpoints}]"
        if c.status and c.status.lower() != "available":
            r.append((label, FAIL, f"status {c.status}"))
        if now and c.end and now > c.end:
            r.append((label, FAIL, f"EXPIRED {c.end:%Y-%m-%d} (device clock {now:%Y-%m-%d})"))
        elif now and c.start and now < c.start:
            r.append((label, FAIL, f"NOT YET VALID until {c.start:%Y-%m-%d} (device clock {now:%Y-%m-%d})"))
        elif c.end:
            r.append((label, PASS, f"valid until {c.end:%Y-%m-%d}"))

    # Telemetry connection state (operational)
    conn = find_section(dev.sections, "show telemetry internal connection",
                        "show telemetry connection all")
    for line in conn.splitlines():
        if re.search(r"\d+\.\d+\.\d+\.\d+|[0-9a-f]+:[0-9a-f:]+", line, re.I) and "Index" not in line:
            state_ok = "active" in line.lower() and "inactive" not in line.lower()
            r.append(("Telemetry connection", PASS if state_ok else FAIL, " ".join(line.split())))
    return r


def _natkey(s: str):
    return [int(t) if t.isdigit() else t for t in re.split(r"(\d+)", s)]


# --------------------------------------------------------------------------
# Config diff
# --------------------------------------------------------------------------
DEVICE_SPECIFIC = [
    (re.compile(r"^(source-address)\s+\S+"), r"\1 <WLC-MGMT-IP>"),
    (re.compile(r"^(certificate(?: self-signed)?)\s+(?!ca\b)\S+"), r"\1 <DEVICE-CERT-SERIAL>"),
]


def normalize(children: list[str]) -> list[str]:
    out = []
    for c in children:
        for rx, rep in DEVICE_SPECIFIC:
            c = rx.sub(rep, c)
        out.append(c)
    return out


def relevant_keys(dev: Device) -> dict[str, str]:
    keys = {}
    mgmt_ifs = set()
    for k in dev.config:
        m = re.match(r"wireless management interface (\S+)", k)
        if m:
            mgmt_ifs.add(f"interface {m.group(1)}")
    for k in dev.config:
        for cat, pat in RELEVANT_PATTERNS.items():
            if re.match(pat, k):
                keys[k] = cat
                break
        else:
            if k in mgmt_ifs:
                keys[k] = "Wireless mgmt interface"
    return keys


def config_diff(good: Device, bad: Device) -> dict[str, list[str]]:
    gk, bk = relevant_keys(good), relevant_keys(bad)
    cats: dict[str, list[str]] = {}
    for key in sorted(set(gk) | set(bk), key=_natkey):
        cat = gk.get(key) or bk.get(key)
        g = normalize(good.config.get(key, [])) if key in good.config else None
        b = normalize(bad.config.get(key, [])) if key in bad.config else None
        lines: list[str] = []
        if g is not None and b is None:
            lines = [f"- {key}"] + [f"-  {c}" for c in g]
        elif b is not None and g is None:
            lines = [f"+ {key}"] + [f"+  {c}" for c in b]
        elif g != b:
            lines = [f"  {key}"]
            for d in difflib.ndiff(g, b):
                if d.startswith(("- ", "+ ")):
                    lines.append(f"{d[0]}  {d[2:]}")
        if lines:
            cats.setdefault(cat, []).append("\n".join(lines))
    return cats


def full_diff(good: Device, bad: Device) -> list[str]:
    def flat(d: Device):
        out = []
        for k, v in d.config.items():
            if k.startswith(("hostname", "ntp clock-period")):
                continue
            out.append(k)
            out.extend(" " + c for c in v)
        return out
    return list(difflib.unified_diff(flat(good), flat(bad), "working", "broken", lineterm="", n=1))


# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------
STYLE = {PASS: "green", FAIL: "bold red", WARN: "yellow", INFO: "cyan"}


def print_checks(good: Device, bad: Device) -> int:
    gres = {name: (st, det) for name, st, det in run_checks(good)}
    bres = run_checks(bad, ref=good)
    rows = []
    fails = 0
    seen = set()
    for name, st, det in bres:
        gst = gres.get(name, ("-", ""))[0]
        flag = st != PASS and gst == PASS
        if st == FAIL:
            fails += 1
        key = (name, det)
        if key in seen:
            continue
        seen.add(key)
        rows.append([("[bold]>> [/]" if flag else "") + name,
                     f"[{STYLE.get(gst, 'dim')}]{gst}[/]",
                     f"[{STYLE.get(st, 'dim')}]{st}[/]", det])
    console.table("Telemetry health checks", ["Check", "Working", "Broken", "Broken detail"], rows)
    console.print("[dim]>> = passes on working WLC but not on broken WLC (strongest lead)[/]\n")
    return fails


def print_diffs(good: Device, bad: Device) -> None:
    cats = config_diff(good, bad)
    if not cats:
        console.panel("No differences in telemetry-relevant config blocks "
                      "(after masking device-specific IPs/serials).", style="green")
        return
    console.rule("[bold]Telemetry-relevant config differences  (- working  /  + broken)")
    for cat, blocks in cats.items():
        console.print(f"\n[bold cyan]## {cat}[/]")
        for blk in blocks:
            for line in blk.splitlines():
                style = "red" if line.startswith("-") else "green" if line.startswith("+") else "bold"
                console.print(line, style=style, markup=False)


def print_ops(good: Device, bad: Device) -> None:
    cmds = ["show telemetry internal connection", "show telemetry connection all",
            "show network-assurance summary", "show clock", "show ntp associations"]
    shown = False
    for cmd in cmds:
        b = find_section(bad.sections, cmd).strip()
        if not b:
            continue
        if not shown:
            console.rule("[bold]Operational state on broken WLC")
            shown = True
        console.print(f"\n[bold]{cmd}[/]")
        console.print(b[:3000], markup=False)


def output_path(ext: str = "txt") -> Path:
    OUTPUT_DIR.mkdir(exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return OUTPUT_DIR / f"{TOOL_ID}_{socket.gethostname().split('.')[0]}_{stamp}.{ext}"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("working", type=Path, help="show tech wireless from WLC with working telemetry")
    ap.add_argument("broken", type=Path, help="show tech wireless from WLC that fails to connect")
    ap.add_argument("--full", action="store_true", help="also print full running-config unified diff")
    ap.add_argument("--no-ops", action="store_true", help="skip operational show output section")
    ap.add_argument("--out", action="store_true", help="also save the report as text to ./output/")
    ap.add_argument("--save", type=Path, help="save report to a text (.txt) or HTML (.html) file")
    a = ap.parse_args()

    for p in (a.working, a.broken):
        if not p.is_file():
            console.print(f"[red]File not found: {p}[/]")
            return 2

    good, bad = load(a.working), load(a.broken)
    console.panel(f"[green]Working:[/] {good.label}  -  {len(good.config)} config blocks, "
                  f"{len(good.sections)} show sections\n"
                  f"[red]Broken:[/]  {bad.label}  -  {len(bad.config)} config blocks, "
                  f"{len(bad.sections)} show sections",
                  title="9800 Catalyst Center telemetry compare")
    if len(good.config) < 5 or len(bad.config) < 5:
        console.print("[yellow]Warning: very little config parsed; check that the files contain "
                      "'show running-config'.[/]")

    fails = print_checks(good, bad)
    print_diffs(good, bad)
    if not a.no_ops:
        print_ops(good, bad)
    if a.full:
        console.rule("[bold]Full running-config diff")
        for line in full_diff(good, bad):
            style = "red" if line.startswith("-") else "green" if line.startswith("+") else None
            console.print(line, style=style, markup=False)

    saves = [a.save] if a.save else []
    if a.out:
        saves.append(output_path())
    for path in saves:
        if path.suffix.lower() in (".html", ".htm"):
            console.save_html(str(path))
        else:
            console.save_text(str(path))
        print(f"\nReport saved to {path}", file=sys.stderr)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
