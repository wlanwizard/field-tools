#!/usr/bin/env python3
# Synopsis: One line describing what this tool does (shows in the README catalog)
# Category: net | sys | ident | sec | cloud | util
# Platform: any
# Requires: python3 (stdlib only)
# Usage:    python3 NNN-verb-noun.py --help
"""
Longer description, examples, and caveats go here.

Rules for tools in this repo:
  - stdlib only, so it runs on a customer laptop with no pip install
  - read-only by default; anything that changes state needs an explicit flag
  - write results to ./output/, never phone home
"""
import argparse
import datetime
import pathlib
import socket
import sys

TOOL_ID = pathlib.Path(__file__).stem.split("-")[0]  # e.g. "001"
OUTPUT_DIR = pathlib.Path(__file__).resolve().parent.parent / "output"


def output_path(ext: str = "txt") -> pathlib.Path:
    """./output/<NNN>_<host>_<yyyymmdd-hhmmss>.<ext>"""
    OUTPUT_DIR.mkdir(exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    return OUTPUT_DIR / f"{TOOL_ID}_{socket.gethostname().split('.')[0]}_{stamp}.{ext}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    parser.add_argument("--out", action="store_true", help="also save results to ./output/")
    args = parser.parse_args()

    results = ["replace me"]

    for line in results:
        print(line)
    if args.out:
        path = output_path()
        path.write_text("\n".join(results) + "\n")
        print(f"[+] saved {path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
