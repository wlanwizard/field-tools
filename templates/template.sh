#!/usr/bin/env bash
# Synopsis: One line describing what this tool does (shows in the README catalog)
# Category: net | sys | ident | sec | cloud | util
# Requires: bash 3.2+ (macOS default)
# Usage:    ./NNN-verb-noun.lm.sh [-o] [-V] [-h]
#
# Rules: read-only by default, no installs, results go to ./output/.
set -euo pipefail

VERSION="1.0.0"   # bump on every change: MAJOR.MINOR.PATCH (see CLAUDE.md)
TOOL_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOL_ID="$(basename "$0" | cut -d- -f1)"            # e.g. 001
OUTPUT_DIR="$SCRIPT_DIR/../output"
SAVE=0

usage() { sed -n 's/^# \{0,1\}//; 2,5p' "$0"; exit "${1:-0}"; }

while getopts "oVh" opt; do
  case "$opt" in
    o) SAVE=1 ;;
    V) echo "$TOOL_NAME v$VERSION"; exit 0 ;;
    h) usage 0 ;;
    *) usage 2 ;;
  esac
done

echo "$TOOL_NAME v$VERSION" >&2   # stderr, so piped / redirected output stays clean

run() {
  echo "replace me"
}

if [[ $SAVE -eq 1 ]]; then
  mkdir -p "$OUTPUT_DIR"
  out="$OUTPUT_DIR/${TOOL_ID}_$(hostname -s)_$(date +%Y%m%d-%H%M%S).txt"
  echo "$TOOL_NAME v$VERSION" > "$out"   # banner already went to the screen via stderr
  run | tee -a "$out"
  echo "[+] saved $out" >&2
else
  run
fi
