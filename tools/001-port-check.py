#!/usr/bin/env python3
# Synopsis: TCP connect test to one or more host:port targets (firewall / ACL validation)
# Category: net
# Platform: any
# Requires: python3 (stdlib only)
# Usage:    python3 001-port-check.py 10.0.0.1:443 dc01:389 -t 2 --out
"""
TCP connect test to one or more host:port targets.

Opens a TCP connection to each target and reports OPEN / CLOSED / TIMEOUT /
DNS-FAIL plus connect latency. Read-only; sends no payload.

Targets come from the command line and/or a file (-f) with one host:port per
line ('#' comments allowed).
"""
import argparse
import concurrent.futures
import datetime
import pathlib
import socket
import sys
import time

TOOL_ID = pathlib.Path(__file__).stem.split("-")[0]
OUTPUT_DIR = pathlib.Path(__file__).resolve().parent.parent / "output"


def output_path(ext: str = "csv") -> pathlib.Path:
    OUTPUT_DIR.mkdir(exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    return OUTPUT_DIR / f"{TOOL_ID}_{socket.gethostname().split('.')[0]}_{stamp}.{ext}"


def check(target: str, timeout: float) -> tuple:
    host, _, port = target.rpartition(":")
    host = host.strip("[]")  # allow [v6]:port
    start = time.perf_counter()
    try:
        with socket.create_connection((host, int(port)), timeout=timeout):
            ms = (time.perf_counter() - start) * 1000
            return target, "OPEN", f"{ms:.1f}"
    except socket.gaierror:
        return target, "DNS-FAIL", ""
    except socket.timeout:
        return target, "TIMEOUT", ""
    except ConnectionRefusedError:
        return target, "CLOSED", ""
    except OSError as e:
        return target, f"ERROR:{e.strerror or e}", ""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    parser.add_argument("targets", nargs="*", help="host:port (e.g. 10.1.1.1:443)")
    parser.add_argument("-f", "--file", type=pathlib.Path, help="file with one host:port per line")
    parser.add_argument("-t", "--timeout", type=float, default=3.0, help="seconds (default 3)")
    parser.add_argument("--out", action="store_true", help="also save CSV to ./output/")
    args = parser.parse_args()

    targets = list(args.targets)
    if args.file:
        for line in args.file.read_text().splitlines():
            line = line.split("#", 1)[0].strip()
            if line:
                targets.append(line)
    if not targets:
        parser.error("no targets given")
    bad = [t for t in targets if ":" not in t or not t.rpartition(":")[2].isdigit()]
    if bad:
        parser.error(f"expected host:port, got: {', '.join(bad)}")

    with concurrent.futures.ThreadPoolExecutor(max_workers=32) as pool:
        results = list(pool.map(lambda t: check(t, args.timeout), targets))

    width = max(len(t) for t in targets)
    print(f"{'TARGET':<{width}}  {'RESULT':<10}  MS")
    for target, status, ms in results:
        print(f"{target:<{width}}  {status:<10}  {ms}")

    if args.out:
        path = output_path()
        rows = ["target,result,ms"] + [",".join(r) for r in results]
        path.write_text("\n".join(rows) + "\n")
        print(f"[+] saved {path}", file=sys.stderr)
    return 0 if all(r[1] == "OPEN" for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
