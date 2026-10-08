#!/usr/bin/env bash
# Synopsis: Pull the TLS certificate from a remote host with openssl and show subject, SANs, expiry, chain and checks
# Category: sec
# Requires: bash 3.2+ and openssl (OpenSSL 1.1+/3.x or macOS LibreSSL); no root needed
# Usage:    ./005-tls-cert-info.lm.sh [-p port] [-s sni] [-w days] [-t secs] [-x] [-o] [-V] [-h] <host | host:port | https://url>
#
# -p port (default 443)   -s SNI name to send (default: the host)   -w warn if expiring within N days (default 30)
# -t connect timeout in seconds (default 10)   -x also print the full openssl text of the server cert   -o save to ./output/
#
# Read-only: one TLS handshake, nothing is sent after it. Checks (PASS/WARN/FAIL): validity dates,
# expiry window, host name vs SANs, chain trust (openssl's own CA store), key size and signature
# hash. Exit 0 = all PASS, 1 = any WARN/FAIL, 2 = bad arguments or could not connect.
set -uo pipefail
# Note: case patterns inside $( ... ) use the (pattern) form; bash 3.2 (macOS) misparses pattern) there.

VERSION="1.0.0"   # bump on every change: MAJOR.MINOR.PATCH (see CLAUDE.md)
TOOL_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOL_ID="$(basename "$0" | cut -d- -f1)"
OUTPUT_DIR="$SCRIPT_DIR/../output"

PORT="" SNI="" WARN_DAYS=30 TIMEOUT=10 FULL=0 SAVE=0 TARGET=""

usage() { sed -n 's/^# \{0,1\}//; 2,8p' "$0"; exit "${1:-0}"; }
die() { echo "$TOOL_NAME: $*" >&2; exit 2; }

# Options may come before or after the host
while [ $# -gt 0 ]; do
  OPTIND=1
  while getopts "p:s:w:t:xoVh" opt; do
    case "$opt" in
      p) PORT=$OPTARG ;;
      s) SNI=$OPTARG ;;
      w) WARN_DAYS=$OPTARG ;;
      t) TIMEOUT=$OPTARG ;;
      x) FULL=1 ;;
      o) SAVE=1 ;;
      V) echo "$TOOL_NAME v$VERSION"; exit 0 ;;
      h) usage 0 ;;
      *) usage 2 ;;
    esac
  done
  shift $(( OPTIND - 1 ))
  if [ $# -gt 0 ]; then
    [ -z "$TARGET" ] || die "only one host at a time"
    TARGET=$1; shift
  fi
done

echo "$TOOL_NAME v$VERSION" >&2   # stderr, so piped / redirected output stays clean

[ -n "$TARGET" ] || usage 2
have() { command -v "$1" >/dev/null 2>&1; }
have openssl || die "openssl not found"

# Accept host, host:port, [v6]:port, or a URL
HOST=${TARGET#*://}; HOST=${HOST%%/*}
case "$HOST" in
  \[*\]:*) [ -n "$PORT" ] || PORT=${HOST##*]:}; HOST=${HOST%%]:*}; HOST=${HOST#[} ;;
  \[*\])   HOST=${HOST#[}; HOST=${HOST%]} ;;
  *:*:*)   ;;                                   # bare IPv6, no port
  *:*)     [ -n "$PORT" ] || PORT=${HOST##*:}; HOST=${HOST%%:*} ;;
esac
[ -n "$PORT" ] || PORT=443
echo "$PORT" | grep -Eq '^[0-9]+$' && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "bad port: $PORT"
echo "$WARN_DAYS" | grep -Eq '^[0-9]+$' || die "-w must be a number of days"
echo "$TIMEOUT" | grep -Eq '^[0-9]+$' && [ "$TIMEOUT" -ge 1 ] || die "-t must be a whole number of seconds"

IS_IP=0
echo "$HOST" | grep -Eq '^[0-9.]+$|:' && IS_IP=1
# SNI must be a name, so an IP target sends none unless -s gives one
[ -n "$SNI" ] || { [ $IS_IP -eq 1 ] || SNI=$HOST; }
case "$HOST" in *:*) CONNECT="[$HOST]:$PORT" ;; *) CONNECT="$HOST:$PORT" ;; esac

OS="$(uname -s)"
if [ -t 1 ] && [ $SAVE -eq 0 ]; then RED=$'\033[31m' GREEN=$'\033[32m' YELLOW=$'\033[33m' RESET=$'\033[0m'
else RED="" GREEN="" YELLOW="" RESET=""; fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/tlscert.XXXXXX") || die "cannot create a temp dir"
trap 'rm -rf "$TMP"' EXIT

# macOS has no `timeout`; run in the background and kill it if it hangs (filtered ports)
with_timeout() {
  local t=$1 p w rc; shift
  "$@" & p=$!
  ( sleep "$t"; kill "$p" 2>/dev/null ) >/dev/null 2>&1 & w=$!
  wait "$p"; rc=$?
  kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
  return $rc
}

section() { printf '\n===== %s =====\n' "$1"; }
field() { printf '%-15s: %s\n' "$1" "$2"; }
cn_of() { sed -n 's/.*CN *= *\([^,/]*\).*/\1/p' | head -1; }
dn_of() { sed 's/^[a-z]*= *//'; }   # strip "subject=" / "issuer="

to_epoch() {   # "Dec 25 22:56:35 2026 GMT" -> seconds
  local d; d=$(echo "$1" | tr -s ' ')
  if [ "$OS" = Darwin ]; then date -j -u -f '%b %d %T %Y %Z' "$d" +%s 2>/dev/null
  else date -u -d "$d" +%s 2>/dev/null; fi
}
ymd() { if [ "$OS" = Darwin ]; then date -u -r "$1" +%F; else date -u -d "@$1" +%F; fi; }

# Does HOST match a SAN entry (or the CN when there are no SANs)? Handles *.example.com
host_matches() {
  local h n suffix names
  h=$(echo "$HOST" | tr 'A-Z' 'a-z')
  names=$(echo "$1" | tr ',' '\n' | sed 's/^ *//; s/^DNS://; s/^IP Address://' | tr 'A-Z' 'a-z')
  for n in $names; do
    [ "$n" = "$h" ] && return 0
    case "$n" in
      '*.'*) suffix=${n#\*.}
             [ "${h#*.}" = "$suffix" ] && [ "$h" != "$suffix" ] && return 0 ;;
    esac
  done
  return 1
}

FAILS=0 WARNS=0
check() {   # check PASS|WARN|FAIL "what" "detail"
  local c=$GREEN
  case "$1" in WARN) c=$YELLOW; WARNS=$(( WARNS + 1 )) ;; FAIL) c=$RED; FAILS=$(( FAILS + 1 )) ;; esac
  printf '%s%-4s%s  %-24s %s\n' "$c" "$1" "$RESET" "$2" "$3"
}

run() {
  local out args protocol cipher verify leaf txt now i f
  args="-connect $CONNECT -showcerts"
  [ -n "$SNI" ] && args="$args -servername $SNI"
  # shellcheck disable=SC2086
  out=$(with_timeout "$TIMEOUT" openssl s_client $args </dev/null 2>&1)

  # Split the presented chain into one PEM file per certificate
  printf '%s\n' "$out" | awk -v dir="$TMP" '
    /-----BEGIN CERTIFICATE-----/ {n++; f = sprintf("%s/cert%02d.pem", dir, n); p = 1}
    p {print > f}
    /-----END CERTIFICATE-----/ {p = 0; close(f)}'
  leaf="$TMP/cert01.pem"
  if [ ! -s "$leaf" ]; then
    echo "Could not get a certificate from $CONNECT${SNI:+ (SNI $SNI)}:" >&2
    printf '%s\n' "$out" | grep -iE 'connect|errno|error|refused|unknown|resolve|alert|timed? ?out' | head -5 | sed 's/^/  /' >&2
    [ -n "$out" ] || echo "  (no response within ${TIMEOUT}s - port filtered or host down?)" >&2
    return 2
  fi

  protocol=$(printf '%s\n' "$out" | sed -n 's/^ *Protocol *: *//p' | head -1)
  cipher=$(printf '%s\n' "$out" | sed -n 's/^ *Cipher *: *//p' | head -1)
  [ -n "$cipher" ] || cipher=$(printf '%s\n' "$out" | sed -n 's/.*Cipher is //p' | head -1)
  verify=$(printf '%s\n' "$out" | sed -n 's/^ *Verify return code: *//p' | tail -1)

  txt=$(openssl x509 -in "$leaf" -noout -text)
  local subject issuer serial start end sans keyalg bits curve sigalg eku fp
  subject=$(openssl x509 -in "$leaf" -noout -subject | dn_of)
  issuer=$(openssl x509 -in "$leaf" -noout -issuer | dn_of)
  serial=$(openssl x509 -in "$leaf" -noout -serial | sed 's/^serial=//')
  start=$(openssl x509 -in "$leaf" -noout -startdate | sed 's/^notBefore=//')
  end=$(openssl x509 -in "$leaf" -noout -enddate | sed 's/^notAfter=//')
  fp=$(openssl x509 -in "$leaf" -noout -fingerprint -sha256 | sed 's/^.*=//')
  sans=$(printf '%s\n' "$txt" | awk '/Subject Alternative Name/ {getline; sub(/^ +/, ""); print; exit}')
  keyalg=$(printf '%s\n' "$txt" | awk -F': ' '/Public Key Algorithm/ {print $2; exit}')
  bits=$(printf '%s\n' "$txt" | sed -n 's/.*Public-Key: (\([0-9]*\) bit).*/\1/p' | head -1)
  curve=$(printf '%s\n' "$txt" | awk -F': ' '/NIST CURVE|ASN1 OID/ {print $2; exit}')
  sigalg=$(printf '%s\n' "$txt" | awk -F': ' '/Signature Algorithm/ {print $2; exit}')
  eku=$(printf '%s\n' "$txt" | awk '/Extended Key Usage/ {getline; sub(/^ +/, ""); print; exit}')

  now=$(date +%s)
  local s_ep e_ep days
  s_ep=$(to_epoch "$start"); e_ep=$(to_epoch "$end")
  days=$(( (e_ep - now) / 86400 ))

  section "CERTIFICATE  $CONNECT${SNI:+  (SNI $SNI)}"
  field "Subject" "$subject"
  field "Issuer" "$issuer"
  field "SANs" "${sans:-(none)}"
  field "Valid from" "$start"
  field "Valid until" "$end  ($days days left)"
  field "Key" "$keyalg${bits:+ $bits bit}${curve:+ $curve}"
  field "Signature" "$sigalg"
  field "Key usage" "${eku:-(not set)}"
  field "Serial" "$serial"
  field "SHA-256" "$fp"

  section "CHAIN (as sent by the server)"
  i=0
  for f in "$TMP"/cert*.pem; do
    local cs ci ce ce_ep note=""
    cs=$(openssl x509 -in "$f" -noout -subject | dn_of)
    ci=$(openssl x509 -in "$f" -noout -issuer | dn_of)
    ce=$(openssl x509 -in "$f" -noout -enddate | sed 's/^notAfter=//')
    ce_ep=$(to_epoch "$ce")
    [ "$cs" = "$ci" ] && note="  (self-signed)"
    printf '%d  %s\n   issued by %s\n   expires %s (%s days)%s\n' "$i" \
      "$(echo "$cs" | cn_of)" "$(echo "$ci" | cn_of)" "$(ymd "$ce_ep")" "$(( (ce_ep - now) / 86400 ))" "$note"
    i=$(( i + 1 ))
  done

  section "CONNECTION"
  field "Protocol" "${protocol:-?}"
  field "Cipher" "${cipher:-?}"
  field "Verify" "${verify:-?}"

  section "CHECKS"
  if [ -z "$s_ep" ] || [ -z "$e_ep" ]; then check WARN "Validity dates" "could not parse '$start' / '$end'"
  elif [ "$now" -lt "$s_ep" ]; then check FAIL "Validity dates" "not valid until $(ymd "$s_ep")"
  elif [ "$now" -gt "$e_ep" ]; then check FAIL "Validity dates" "EXPIRED on $(ymd "$e_ep")"
  else check PASS "Validity dates" "valid $(ymd "$s_ep") to $(ymd "$e_ep")"; fi
  if [ -n "$e_ep" ] && [ "$now" -le "$e_ep" ]; then
    if [ "$days" -lt "$WARN_DAYS" ]; then check WARN "Expiry" "$days days left (warn under $WARN_DAYS)"
    else check PASS "Expiry" "$days days left"; fi
  fi
  local names=$sans
  [ -n "$names" ] || names="DNS:$(echo "$subject" | cn_of)"
  if host_matches "$names"; then check PASS "Host name" "$HOST is covered"
  else check FAIL "Host name" "$HOST is not in the certificate's SANs"; fi
  case "$verify" in
    0\ *) check PASS "Chain trust" "verified against openssl's CA store" ;;
    "")   check WARN "Chain trust" "openssl did not report a result" ;;
    *)    check FAIL "Chain trust" "$verify" ;;
  esac
  if [ -n "$bits" ] && echo "$keyalg" | grep -qi rsa && [ "$bits" -lt 2048 ]; then
    check FAIL "Key size" "RSA $bits bit (under 2048)"
  else check PASS "Key size" "$keyalg${bits:+ $bits bit}"; fi
  if echo "$sigalg" | grep -qiE 'sha1|md5'; then check FAIL "Signature hash" "$sigalg"
  else check PASS "Signature hash" "$sigalg"; fi

  if [ $FULL -eq 1 ]; then
    section "FULL CERTIFICATE TEXT"
    printf '%s\n' "$txt"
  fi
  [ $(( FAILS + WARNS )) -eq 0 ]
}

if [ $SAVE -eq 1 ]; then
  mkdir -p "$OUTPUT_DIR"
  out_file="$OUTPUT_DIR/${TOOL_ID}_$(hostname -s)_$(date +%Y%m%d-%H%M%S).txt"
  echo "$TOOL_NAME v$VERSION" > "$out_file"   # banner already went to the screen via stderr
  run | tee -a "$out_file"; rc=${PIPESTATUS[0]}
  echo "[+] saved $out_file" >&2
else
  run; rc=$?
fi
exit $rc
