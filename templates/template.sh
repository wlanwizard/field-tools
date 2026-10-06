#!/usr/bin/env bash
# Synopsis: One line describing what this tool does (shows in the README catalog)
# Category: net | sys | ident | sec | cloud | util
# Requires: bash 3.2+ (macOS default)
# Usage:    ./NNN-verb-noun.lm.sh [-o] [-h]
#
# Rules: read-only by default, no installs, results go to ./output/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOL_ID="$(basename "$0" | cut -d- -f1)"            # e.g. 001
OUTPUT_DIR="$SCRIPT_DIR/../output"
SAVE=0

usage() { sed -n 's/^# \{0,1\}//; 2,5p' "$0"; exit "${1:-0}"; }

while getopts "oh" opt; do
  case "$opt" in
    o) SAVE=1 ;;
    h) usage 0 ;;
    *) usage 2 ;;
  esac
done

run() {
  echo "replace me"
}

if [[ $SAVE -eq 1 ]]; then
  mkdir -p "$OUTPUT_DIR"
  out="$OUTPUT_DIR/${TOOL_ID}_$(hostname -s)_$(date +%Y%m%d-%H%M%S).txt"
  run | tee "$out"
  echo "[+] saved $out" >&2
else
  run
fi
