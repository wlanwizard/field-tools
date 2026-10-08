#!/usr/bin/env bash
# Synopsis: Ping one host continuously and log timestamped UP/DOWN changes with outage durations
# Category: net
# Requires: bash 3.2+ and the system ping (macOS, Linux iputils or busybox); no root needed
# Usage:    ./004-ping-monitor.lm.sh [-i secs] [-t ms] [-f count] [-o] [-V] [-h] <host or IP>
#
# -i interval in seconds (default 1)   -t reply timeout in ms (default 1000)
# -f missed replies in a row before DOWN (default 2)   -o also log events to ./output/ as CSV
#
# macOS/Linux version of 004-ping-monitor.w.ps1, same behaviour and output. Ctrl+C stops and
# prints a summary. A host is DOWN after -f missed replies in a row, timestamped at the first
# miss, and UP again on the first reply. IPv6 on macOS uses ping6, which has no timeout option.
set -uo pipefail   # no -e: a failed ping is a normal result here
# Note: case patterns inside $( ... ) use the (pattern) form; bash 3.2 (macOS) misparses pattern) there.

VERSION="1.0.0"   # bump on every change: MAJOR.MINOR.PATCH (see CLAUDE.md)
TOOL_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOL_ID="$(basename "$0" | cut -d- -f1)"
OUTPUT_DIR="$SCRIPT_DIR/../output"

INTERVAL=1 TIMEOUT_MS=1000 FAILCOUNT=2 SAVE=0 TARGET=""

usage() { sed -n 's/^# \{0,1\}//; 2,8p' "$0"; exit "${1:-0}"; }
die() { echo "$TOOL_NAME: $*" >&2; exit 2; }

# Options may come before or after the host
while [ $# -gt 0 ]; do
  OPTIND=1
  while getopts "i:t:f:oVh" opt; do
    case "$opt" in
      i) INTERVAL=$OPTARG ;;
      t) TIMEOUT_MS=$OPTARG ;;
      f) FAILCOUNT=$OPTARG ;;
      o) SAVE=1 ;;
      V) echo "$TOOL_NAME v$VERSION"; exit 0 ;;
      h) usage 0 ;;
      *) usage 2 ;;
    esac
  done
  shift $(( OPTIND - 1 ))
  if [ $# -gt 0 ]; then
    [ -z "$TARGET" ] || die "only one host can be monitored at a time"
    TARGET=$1; shift
  fi
done

echo "$TOOL_NAME v$VERSION" >&2   # stderr, so piped / redirected output stays clean

[ -n "$TARGET" ] || usage 2
echo "$INTERVAL" | grep -Eq '^[0-9]+([.][0-9]+)?$' &&
  awk -v v="$INTERVAL" 'BEGIN {exit !(v >= 0.2 && v <= 3600)}' || die "-i must be 0.2 to 3600 seconds"
echo "$TIMEOUT_MS" | grep -Eq '^[0-9]+$' && [ "$TIMEOUT_MS" -ge 100 ] && [ "$TIMEOUT_MS" -le 60000 ] ||
  die "-t must be 100 to 60000 ms"
echo "$FAILCOUNT" | grep -Eq '^[0-9]+$' && [ "$FAILCOUNT" -ge 1 ] && [ "$FAILCOUNT" -le 1000 ] ||
  die "-f must be 1 to 1000"

OS="$(uname -s)"
case "$TARGET" in *:*) V6=1 ;; *) V6=0 ;; esac
WAIT_S=$(( (TIMEOUT_MS + 999) / 1000 ))   # Linux ping -W takes whole seconds
NFLAG="-n"                                # numeric output; busybox ping doesn't know -n
ping -n -c 1 127.0.0.1 >/dev/null 2>&1 || NFLAG=""

ping_once() {
  if [ "$OS" = Darwin ]; then
    if [ $V6 -eq 1 ]; then ping6 -c 1 "$TARGET"
    else ping $NFLAG -c 1 -i 0.1 -W "$TIMEOUT_MS" "$TARGET"; fi   # -W is ms; -i 0.1 stops a ~1 s extra wait
  else
    ping $NFLAG -c 1 -W "$WAIT_S" "$TARGET"                # picks IPv4/IPv6 from the address
  fi
}

if [ -t 1 ]; then
  IS_TTY=1 RED=$'\033[31m' GREEN=$'\033[32m' GRAY=$'\033[90m' RESET=$'\033[0m'
else
  IS_TTY=0 RED="" GREEN="" GRAY="" RESET=""
fi

CSV=""
if [ $SAVE -eq 1 ]; then
  mkdir -p "$OUTPUT_DIR"
  CSV="$OUTPUT_DIR/${TOOL_ID}_$(hostname -s)_$(date +%Y%m%d-%H%M%S).csv"
  echo '"Time","Target","State","Detail"' > "$CSV"   # same columns as the .w.ps1 version
fi

fmt_dur() { printf '%02d:%02d:%02d' $(( $1 / 3600 )) $(( $1 % 3600 / 60 )) $(( $1 % 60 )); }

STATUS_LEN=0   # length of the live status line, so events can blank it out first

event() {   # event STAMP STATE DETAIL
  local color=$GRAY
  case "$2" in UP) color=$GREEN ;; DOWN) color=$RED ;; esac
  [ $IS_TTY -eq 1 ] && printf '\r%*s\r' "$STATUS_LEN" ''
  printf '%s%s  %-5s  %s  %s%s\n' "$color" "$1" "$2" "$TARGET" "$3" "$RESET"
  # Appended per event, so the log survives Ctrl+C or a closed terminal
  [ -n "$CSV" ] && printf '"%s","%s","%s","%s"\n' "$1" "$TARGET" "$2" "$(printf '%s' "$3" | sed 's/"/""/g')" >> "$CSV"
  return 0
}

STATE=START STATE_SINCE=$(date +%s) STARTED=$(date +%s)
MISSED=0 FIRST_MISS=0 FIRST_MISS_STAMP="" LAST_FAIL=""
SENT=0 LOST=0 OUTAGES=0 DOWN_TOTAL=0 LONGEST=0

finish() {
  local end dur loss
  end=$(date +%s)
  if [ "$STATE" = DOWN ]; then
    dur=$(( end - STATE_SINCE )); DOWN_TOTAL=$(( DOWN_TOTAL + dur ))
    [ $dur -gt $LONGEST ] && LONGEST=$dur
  fi
  loss=$(awk -v l=$LOST -v s=$SENT 'BEGIN {printf "%.1f", (s ? 100 * l / s : 0)}')
  event "$(date '+%Y-%m-%d %H:%M:%S')" STOP "ran $(fmt_dur $(( end - STARTED ))), sent $SENT, lost $LOST ($loss%), outages $OUTAGES, total down $(fmt_dur $DOWN_TOTAL), longest $(fmt_dur $LONGEST), ended $STATE"
  [ -n "$CSV" ] && echo "[+] saved $CSV" >&2
  exit 0
}
trap finish INT TERM   # Ctrl+C prints the summary

if [ "$OS" = Darwin ]; then
  resolved=$(dscacheutil -q host -a name "$TARGET" 2>/dev/null | awk '/address:/ {print $2}' | paste -sd, - | sed 's/,/, /g')
else
  resolved=$(getent ahosts "$TARGET" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd, - | sed 's/,/, /g')
fi
[ -n "$resolved" ] || resolved="does not resolve yet, will keep trying"
event "$(date '+%Y-%m-%d %H:%M:%S')" START "[$resolved] every ${INTERVAL}s, timeout $TIMEOUT_MS ms, DOWN after $FAILCOUNT missed - Ctrl+C to stop"

while true; do
  now=$(date +%s); stamp=$(date '+%Y-%m-%d %H:%M:%S')
  SENT=$(( SENT + 1 ))
  out=$(ping_once 2>&1); rc=$?
  rtt=""
  [ $rc -eq 0 ] && rtt=$(printf '%s\n' "$out" | sed -n 's/.*time[=<] *\([0-9.]*\) *ms.*/\1/p' | head -1)

  if [ -n "$rtt" ]; then
    rtt=$(printf '%.1f' "$rtt")
    if [ "$STATE" = DOWN ]; then
      dur=$(( now - STATE_SINCE )); DOWN_TOTAL=$(( DOWN_TOTAL + dur ))
      [ $dur -gt $LONGEST ] && LONGEST=$dur
      event "$stamp" UP "reply $rtt ms, was down $(fmt_dur $dur)"
    elif [ "$STATE" = START ]; then
      event "$stamp" UP "reply $rtt ms"
    fi
    [ "$STATE" = UP ] || { STATE=UP; STATE_SINCE=$now; }
    MISSED=0
    last="$rtt ms"
  else
    LOST=$(( LOST + 1 ))
    # Name the failure like Windows does; anything else with no reply is a timeout
    LAST_FAIL=$(printf '%s\n' "$out" | grep -iE 'resolve|unknown host|not known|unreachable|no route|network is|failure' |
      head -1 | sed 's/^ping6*: //')
    [ -n "$LAST_FAIL" ] || LAST_FAIL=TimedOut
    if [ $MISSED -eq 0 ]; then FIRST_MISS=$now; FIRST_MISS_STAMP=$stamp; fi
    MISSED=$(( MISSED + 1 ))
    if [ "$STATE" != DOWN ] && [ $MISSED -ge $FAILCOUNT ]; then
      OUTAGES=$(( OUTAGES + 1 ))
      detail="$MISSED missed in a row ($LAST_FAIL)"
      [ "$STATE" = UP ] && detail="$detail, was up $(fmt_dur $(( FIRST_MISS - STATE_SINCE )))"
      # Timestamp the outage at the first missed reply, not when it was confirmed
      event "$FIRST_MISS_STAMP" DOWN "$detail"
      STATE=DOWN; STATE_SINCE=$FIRST_MISS
    fi
    last=$LAST_FAIL
  fi

  if [ $IS_TTY -eq 1 ]; then
    status=$(printf '  %s for %s | sent %d, lost %d (%s%%) | last: %s' "$STATE" "$(fmt_dur $(( $(date +%s) - STATE_SINCE )))" \
      "$SENT" "$LOST" "$(awk -v l=$LOST -v s=$SENT 'BEGIN {printf "%.1f", 100 * l / s}')" "$last")
    printf '\r%-*s' "$STATUS_LEN" "$status"
    STATUS_LEN=${#status}
  fi

  # A timed-out ping already waited for the timeout, so only sleep the rest of the interval
  if [ "$LAST_FAIL" = TimedOut ] && [ -z "$rtt" ]; then
    nap=$(awk -v i="$INTERVAL" -v t="$TIMEOUT_MS" 'BEGIN {d = i - t / 1000; print (d > 0 ? d : 0)}')
  else
    nap=$INTERVAL
  fi
  sleep "$nap"
done
