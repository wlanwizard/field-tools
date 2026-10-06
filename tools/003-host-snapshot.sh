#!/usr/bin/env bash
# Synopsis: Quick host snapshot - OS, uptime, interfaces, routes, DNS, listening ports
# Category: sys
# Platform: mac, linux
# Requires: bash 3.2+ (macOS default); uses whatever of ip/ifconfig/netstat/ss exists
# Usage:    ./003-host-snapshot.sh [-o] [-h]
#
# Rules: read-only by default, no installs, results go to ./output/.
set -uo pipefail   # no -e: a missing command in one section shouldn't stop the rest

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOL_ID="$(basename "$0" | cut -d- -f1)"
OUTPUT_DIR="$SCRIPT_DIR/../output"
SAVE=0

usage() { sed -n 's/^# \{0,1\}//; 2,6p' "$0"; exit "${1:-0}"; }

while getopts "oh" opt; do
  case "$opt" in
    o) SAVE=1 ;;
    h) usage 0 ;;
    *) usage 2 ;;
  esac
done

have() { command -v "$1" >/dev/null 2>&1; }
section() { printf '\n===== %s =====\n' "$1"; }

run() {
  section "HOST";  hostname; date; uptime
  section "OS"
  if have sw_vers; then sw_vers; else cat /etc/os-release 2>/dev/null || uname -a; fi
  section "INTERFACES"
  if have ip; then ip -br addr; else ifconfig | grep -E '^[a-z]|inet '; fi
  section "ROUTES"
  if have ip; then ip route; else netstat -rn -f inet; fi
  section "DNS"
  if have scutil; then scutil --dns | grep -E 'nameserver|search domain' | sort -u
  else grep -vE '^\s*#' /etc/resolv.conf; fi
  section "LISTENING TCP"
  if have ss; then ss -tlnp 2>/dev/null
  elif have lsof; then lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null
  else netstat -an | grep LISTEN; fi
}

if [[ $SAVE -eq 1 ]]; then
  mkdir -p "$OUTPUT_DIR"
  out="$OUTPUT_DIR/${TOOL_ID}_$(hostname -s)_$(date +%Y%m%d-%H%M%S).txt"
  run 2>&1 | tee "$out"
  echo "[+] saved $out" >&2
else
  run
fi
