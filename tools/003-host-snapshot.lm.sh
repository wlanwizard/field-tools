#!/usr/bin/env bash
# Synopsis: Quick host snapshot - current IP, Ethernet/Wi-Fi MAC with adapter model and driver, OS, uptime, DNS servers in use, optional interfaces and routes
# Category: sys
# Requires: bash 3.2+; macOS built-ins, or Linux with iproute2 (lspci, ethtool, resolvectl used if present)
# Usage:    ./003-host-snapshot.lm.sh [-i] [-r] [-o] [-V] [-h]
#
# -i adds all interfaces and IP addresses, -r adds the routing table, -o also saves to ./output/
#
# macOS/Linux version of 003-host-snapshot.w.ps1, same sections. Read-only, no root needed.
# On macOS the adapter model comes from system_profiler, which takes a few seconds.
set -uo pipefail   # no -e: a missing command in one section shouldn't stop the rest
# Note: case patterns inside $( ... ) use the (pattern) form; bash 3.2 (macOS) misparses pattern) there.

VERSION="1.0.1"   # bump on every change: MAJOR.MINOR.PATCH (see CLAUDE.md)
TOOL_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOL_ID="$(basename "$0" | cut -d- -f1)"
OUTPUT_DIR="$SCRIPT_DIR/../output"
SAVE=0 INTERFACES=0 ROUTES=0

usage() { sed -n 's/^# \{0,1\}//; 2,7p' "$0"; exit "${1:-0}"; }

while getopts "iroVh" opt; do
  case "$opt" in
    i) INTERFACES=1 ;;
    r) ROUTES=1 ;;
    o) SAVE=1 ;;
    V) echo "$TOOL_NAME v$VERSION"; exit 0 ;;
    h) usage 0 ;;
    *) usage 2 ;;
  esac
done

echo "$TOOL_NAME v$VERSION" >&2   # stderr, so piped / redirected output stays clean

OS="$(uname -s)"
NL='
'
have() { command -v "$1" >/dev/null 2>&1; }
section() { printf '\n===== %s =====\n' "$1"; }

# Like PowerShell's Format-Table: tab-separated rows on stdin, first row is the header
table() {
  awk -F'\t' '
    { for (i = 1; i <= NF; i++) { c[NR, i] = $i; if (length($i) > w[i]) w[i] = length($i) }
      if (NF > n) n = NF }
    END {
      for (r = 1; r <= NR; r++) {
        line = ""
        for (i = 1; i <= n; i++) line = line (i < n ? sprintf("%-" w[i] "s  ", c[r, i]) : c[r, i])
        print line
        if (r == 1) {
          line = ""
          for (i = 1; i <= n; i++) { d = ""; for (k = 0; k < w[i]; k++) d = d "-"; line = line d (i < n ? "  " : "") }
          print line
        }
      }
    }'
}

# "Label        : first value" then continuation lines aligned under it
rowlines() {
  local label=$1 text=${2:-} first=1 line
  [ -n "$text" ] || text="(none found)"
  while IFS= read -r line; do
    if [ $first -eq 1 ]; then printf '%-13s: %s\n' "$label" "$line"; first=0
    else printf '%-13s  %s\n' "" "$line"; fi
  done <<EOF
$text
EOF
}

mask2prefix() {   # 0xffffff00 -> 24
  local m=$(( $1 )) n=0
  while [ $m -gt 0 ]; do n=$(( n + (m & 1) )); m=$(( m >> 1 )); done
  echo $n
}

# ---------------------------------------------------------------- macOS helpers
PORTS=""   # dev<TAB>hardware port<TAB>burned-in MAC, from networksetup
SP=""      # system_profiler output, read once
if [ "$OS" = Darwin ]; then
  PORTS=$(networksetup -listallhardwareports 2>/dev/null | awk -F': ' '
    /^Hardware Port:/ {port = $2} /^Device:/ {dev = $2} /^Ethernet Address:/ {print dev "\t" port "\t" $2}')
  DEF_IF=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')
else
  DEF_IF=$(ip -4 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
fi

port_name() { printf '%s\n' "$PORTS" | awk -F'\t' -v d="$1" '$1 == d {print $2; exit}'; }

# MAC in use. macOS shows 02:00:00:00:00:00 to shells it didn't sign (e.g. Homebrew bash),
# so fall back to the hardware address from networksetup and say so.
mac_ether() {
  local e; e=$(ifconfig "$1" 2>/dev/null | awk '/ether / {print $2; exit}')
  if [ "$e" = 02:00:00:00:00:00 ]; then
    e=$(printf '%s\n' "$PORTS" | awk -F'\t' -v d="$1" '$1 == d {print $3; exit}')
    [ -n "$e" ] && e="$e ${2:-(hardware)}"
  fi
  echo "$e"
}

mac_status() {
  local s; s=$(ifconfig "$1" 2>/dev/null) || { echo "Not present"; return; }
  case "$s" in
    *"<UP"*) ;;
    *) echo Disabled; return ;;
  esac
  case "$s" in *"status: inactive"*) echo Disconnected ;; *) echo Up ;; esac
}

mac_model() {   # mac_model DEV wifi|eth
  local info ct phy ver d
  if [ "$2" = wifi ]; then
    info=$(printf '%s\n' "$SP" | awk -v dev="$1" '
      $0 ~ "^ +" dev ":$" {f = 1; next}
      f && /^ +[a-z]+[0-9]+:$/ {f = 0}
      f && /Card Type:/ {sub(/^.*Card Type: */, ""); gsub(/  +/, " "); ct = $0}
      f && /Firmware Version:/ {fw = $0}
      f && /Supported PHY Modes:/ {sub(/^.*Modes: */, ""); phy = $0}
      END {
        if (match(fw, /version [^ ]+/)) v = substr(fw, RSTART + 8, RLENGTH - 8)
        if (match(fw, /[A-Z][a-z][a-z] +[0-9]+ [0-9][0-9][0-9][0-9]/)) d = substr(fw, RSTART, RLENGTH)
        print ct "|" phy "|" v "|" d
      }')
    IFS='|' read -r ct phy ver d <<EOF
$info
EOF
    [ -n "$d" ] && d=$(date -j -f '%b %d %Y' "$(echo "$d" | tr -s ' ')" +%F 2>/dev/null)
    if [ -n "$ct" ]; then echo "  $ct${phy:+, $phy}  firmware ${ver:-?}${d:+ ($d)}"
    else echo "  (model not reported by system_profiler)"; fi
  else
    info=$(printf '%s\n' "$SP" | awk -v dev="$1" '
      /^    [^ ].*:$/ {hdr = $0; sub(/^ +/, "", hdr); sub(/:$/, "", hdr); drv = ""}
      /Driver:/ {drv = $0; sub(/^.*Driver: */, "", drv)}
      /BSD Device Name:/ {n = $0; sub(/^.*Name: */, "", n); if (n == dev) {print hdr "|" drv; exit}}')
    if [ -n "$info" ]; then echo "  ${info%%|*}  driver ${info#*|}"
    else echo "  (model not reported by system_profiler)"; fi
  fi
}

# ---------------------------------------------------------------- Linux helpers
ETHTOOL=$(command -v ethtool || ls /usr/sbin/ethtool /sbin/ethtool 2>/dev/null | head -1)

lin_status() {
  local f; f=$(cat "/sys/class/net/$1/flags" 2>/dev/null)
  if [ -n "$f" ] && [ $(( f & 1 )) -eq 0 ]; then echo Disabled; return; fi
  case "$(cat "/sys/class/net/$1/operstate" 2>/dev/null)" in up) echo Up ;; *) echo Disconnected ;; esac
}

lin_model() {   # model name, driver, driver/firmware version
  local n=$1 dev sub m="" drv ver="" fw=""
  dev=$(readlink -f "/sys/class/net/$n/device")
  sub=$(basename "$(readlink -f "$dev/subsystem")")
  if [ "$sub" = pci ] && have lspci; then
    m=$(lspci -s "$(basename "$dev")" 2>/dev/null | sed 's/^[^ ]* [^:]*: //')
  elif [ "$sub" = usb ]; then
    m="$(cat "$dev/../manufacturer" 2>/dev/null) $(cat "$dev/../product" 2>/dev/null)"
  fi
  m=$(echo $m)
  [ -n "$m" ] || m="($sub adapter, model not reported)"
  drv=$(basename "$(readlink -f "$dev/driver")")
  if [ -n "$ETHTOOL" ]; then
    ver=$("$ETHTOOL" -i "$n" 2>/dev/null | awk -F': ' '$1 == "version" {print $2}')
    fw=$("$ETHTOOL" -i "$n" 2>/dev/null | awk -F': ' '$1 == "firmware-version" && $2 != "" && $2 != "N/A" {print $2}')
  fi
  [ -n "$ver" ] || ver=$(cat "/sys/module/$drv/version" 2>/dev/null)
  echo "  $m  driver $drv${ver:+ $ver}${fw:+ (firmware $fw)}"
}

# ---------------------------------------------------------------- sections
ip_and_mac() {
  section "IP AND MAC"
  local ips="" eth="" wifi="" dev port hw kind cur l1 l2

  # Connected IPv4 addresses; the interface with the default route is the one in use
  if [ "$OS" = Darwin ]; then
    ips=$(for dev in $(ifconfig -lu); do
      [ "$dev" = lo0 ] && continue
      s=$(ifconfig "$dev"); case "$s" in (*"status: inactive"*) continue ;; esac
      gw=$(ipconfig getoption "$dev" router 2>/dev/null)
      name=$(port_name "$dev"); name=${name:+$name [$dev]}
      printf '%s\n' "$s" | awk '/inet / {print $2, $4}' | while read -r a m; do
        key=1; [ "$dev" = "$DEF_IF" ] && key=0
        echo "$key $a/$(mask2prefix "$m") on ${name:-$dev}${gw:+ (gateway $gw)}"
      done
    done | sort -s -k1,1 | cut -d' ' -f2-)
  else
    ips=$(ip -4 -o addr show scope global 2>/dev/null | while read -r _ dev _ cidr _; do
      dev=${dev%%@*}
      case "$(cat "/sys/class/net/$dev/operstate" 2>/dev/null)" in (up|unknown) ;; (*) continue ;; esac
      gw=$(ip -4 route show default dev "$dev" 2>/dev/null | awk '/via/ {print $3; exit}')
      key=1; [ "$dev" = "$DEF_IF" ] && key=0
      echo "$key $cidr on $dev${gw:+ (gateway $gw)}"
    done | sort -s -k1,1 | cut -d' ' -f2-)
  fi
  rowlines "Current IP" "$ips"

  # Physical adapters only (no VPN / bridge / VM NICs). Wi-Fi shows the MAC in use,
  # which is a random one if private / randomized addresses are on.
  if [ "$OS" = Darwin ]; then
    echo "(reading adapter models from system_profiler, a few seconds...)" >&2
    SP=$(system_profiler SPAirPortDataType SPEthernetDataType 2>/dev/null)
    while IFS="$(printf '\t')" read -r dev port hw; do
      [ -n "$dev" ] || continue
      case "${hw:1:1}" in [26aeAE]) continue ;; esac   # locally administered = virtual
      case "$port" in
        Wi-Fi|AirPort) kind=wifi ;;
        *Bridge*) continue ;;
        *Ethernet*|*LAN*) kind=eth ;;
        *) continue ;;
      esac
      cur=$(mac_ether "$dev" "(hardware address; macOS hid the in-use MAC)")
      l1="${cur:-$hw}  $port [$dev] ($(mac_status "$dev"))"
      l2=$(mac_model "$dev" "$kind")
      if [ $kind = wifi ]; then wifi="$wifi${wifi:+$NL}$l1$NL$l2"; else eth="$eth${eth:+$NL}$l1$NL$l2"; fi
    done <<EOF
$PORTS
EOF
  else
    for d in /sys/class/net/*; do
      [ -e "$d/device" ] || continue                   # no device = virtual
      [ "$(cat "$d/type" 2>/dev/null)" = 1 ] || continue
      dev=${d##*/}
      l1="$(cat "$d/address")  $dev ($(lin_status "$dev"))"
      l2=$(lin_model "$dev")
      if [ -d "$d/wireless" ] || [ -e "$d/phy80211" ]; then wifi="$wifi${wifi:+$NL}$l1$NL$l2"
      else eth="$eth${eth:+$NL}$l1$NL$l2"; fi
    done
  fi
  rowlines "Ethernet MAC" "$eth"
  rowlines "Wi-Fi MAC" "$wifi"
}

host_info() {
  section "HOST"
  local domain="" boot now up
  if [ "$OS" = Darwin ]; then
    domain=$(dsconfigad -show 2>/dev/null | awk -F'= ' '/Active Directory Domain/ {print $2}')
    boot=$(sysctl -n kern.boottime | sed 's/^{ sec = \([0-9]*\).*/\1/')
  else
    have realm && domain=$(realm list --name-only 2>/dev/null | head -1)
    boot=$(( $(date +%s) - $(cut -d. -f1 /proc/uptime) ))
  fi
  [ -n "$domain" ] || domain="(not domain joined)"
  now=$(date +%s); up=$(( now - boot ))
  printf '%-9s: %s\n' Hostname "$(hostname)" Domain "$domain" \
    Date "$(date '+%Y-%m-%d %H:%M:%S %z')" \
    LastBoot "$(if [ "$OS" = Darwin ]; then date -r "$boot" '+%Y-%m-%d %H:%M:%S'; else date -d "@$boot" '+%Y-%m-%d %H:%M:%S'; fi)" \
    Uptime "$(( up / 86400 ))d $(( up % 86400 / 3600 ))h $(( up % 3600 / 60 ))m"
}

os_info() {
  section "OS"
  local name rel build inst
  if [ "$OS" = Darwin ]; then
    name=$(sw_vers -productName); rel=$(sw_vers -productVersion); build=$(sw_vers -buildVersion)
    inst=$(stat -f %SB -t %Y-%m-%d /var/db/.AppleSetupDone 2>/dev/null)
  else
    name=$( . /etc/os-release 2>/dev/null; echo "${NAME:-Linux}")
    rel=$( . /etc/os-release 2>/dev/null; echo "${VERSION:-${VERSION_ID:-?}}")
    build="kernel $(uname -r)"
    inst=$(stat -c %w / 2>/dev/null | cut -d' ' -f1); [ "$inst" = "-" ] && inst=""
  fi
  printf '%-12s: %s\n' OS "$name" Release "$rel" Build "$build" \
    Architecture "$(uname -m)" InstallDate "${inst:-(unknown)}" Shell "bash $BASH_VERSION"
}

interfaces() {
  section "INTERFACES"
  local d dev s
  if [ "$OS" = Darwin ]; then
    { printf 'Name\tPort\tStatus\tMedia\tMAC\n'
      for dev in $(ifconfig -l); do
        s=$(ifconfig "$dev")
        printf '%s\t%s\t%s\t%s\t%s\n' "$dev" "$(port_name "$dev")" "$(mac_status "$dev")" \
          "$(printf '%s\n' "$s" | sed -n 's/.*media: [^(]*(\(.*\)).*/\1/p' | head -1)" \
          "$(mac_ether "$dev")"
      done; } | table
    echo
    { printf 'Interface\tFamily\tAddress\n'
      for dev in $(ifconfig -l); do
        ifconfig "$dev" | awk -v i="$dev" '
          function bits(h,   n, k, c) { n = 0; h = tolower(substr(h, 3))
            for (k = 1; k <= length(h); k++) { c = index("0123456789abcdef", substr(h, k, 1)) - 1
              n += substr("0112122312232334", c + 1, 1) }
            return n }
          /inet / {print i "\tIPv4\t" $2 "/" bits($4)}
          /inet6 / {print i "\tIPv6\t" $2 "/" $4}'
      done; } | table
  else
    { printf 'Name\tStatus\tSpeed\tMAC\n'
      for d in /sys/class/net/*; do
        dev=${d##*/}; s=$(cat "$d/speed" 2>/dev/null)
        case "$s" in ''|-1) s=- ;; *) s="$s Mb/s" ;; esac
        printf '%s\t%s\t%s\t%s\n' "$dev" "$(lin_status "$dev")" "$s" "$(cat "$d/address" 2>/dev/null)"
      done; } | table
    echo
    { printf 'Interface\tFamily\tAddress\n'
      ip -o addr show 2>/dev/null | awk '{print $2 "\t" ($3 == "inet" ? "IPv4" : "IPv6") "\t" $4}'; } | table
  fi
}

routes() {
  section "ROUTES"
  # macOS netstat mixes in ARP cache entries (flag L); leave those out, like Windows Get-NetRoute
  if [ "$OS" = Darwin ]; then netstat -rn -f inet | awk '$3 !~ /L/'; else ip -4 route; fi
}

dns_in_use() {
  section "DNS SERVERS IN USE"
  local rows="" search="" dev servers gw key
  if [ "$OS" = Darwin ]; then
    # Per-interface resolvers ("scoped queries") only exist for active interfaces
    rows=$(scutil --dns | awk '
      /for scoped queries/ {s = 1}
      s && /^resolver #/ {if (ifn != "") print ifn "\t" ns; ns = ""; ifn = ""}
      s && /nameserver\[/ {sub(/.*: /, ""); ns = ns (ns ? ", " : "") $0}
      s && /if_index/ {ifn = $NF; gsub(/[()]/, "", ifn)}
      END {if (ifn != "") print ifn "\t" ns}' |
      while IFS="$(printf '\t')" read -r dev servers; do
        [ -n "$servers" ] || continue
        gw=$(ipconfig getoption "$dev" router 2>/dev/null)
        key=1; [ "$dev" = "$DEF_IF" ] && key=0
        name=$(port_name "$dev")
        printf '%s\t%s\t%s\t%s\n' "$key" "${name:+$name }[$dev]" "${gw}" "$servers"
      done)
    search=$(scutil --dns | awk -F' : ' '/search domain/ {print $2}' | sort -u | paste -sd, - | sed 's/,/, /g')
  elif have resolvectl && resolvectl dns >/dev/null 2>&1; then
    rows=$(resolvectl dns 2>/dev/null | while IFS= read -r line; do
      case "$line" in
        (Link*) dev=$(printf '%s' "$line" | sed -n 's/^Link [0-9]* (\([^)]*\)).*/\1/p')
                servers=$(printf '%s' "$line" | sed 's/^[^)]*)://')
                case "$(cat "/sys/class/net/$dev/operstate" 2>/dev/null)" in (up|unknown) ;; (*) continue ;; esac ;;
        (Global*) dev="(global)"; servers=${line#Global:} ;;
        (*) continue ;;
      esac
      servers=$(echo $servers | sed 's/ /, /g')
      [ -n "$servers" ] || continue
      gw=$(ip -4 route show default dev "$dev" 2>/dev/null | awk '/via/ {print $3; exit}')
      key=1; [ "$dev" = "$DEF_IF" ] && key=0
      printf '%s\t%s\t%s\t%s\n' "$key" "$dev" "$gw" "$servers"
    done)
    search=$(resolvectl domain 2>/dev/null | sed 's/^[^:]*://' | tr ' ' '\n' | grep -v '^$' | sort -u | paste -sd, - | sed 's/,/, /g')
  else
    servers=$(awk '/^nameserver/ {printf "%s%s", (n++ ? ", " : ""), $2}' /etc/resolv.conf 2>/dev/null)
    [ -n "$servers" ] && rows=$(printf '0\t(resolv.conf)\t%s\t%s' "$(ip -4 route show default 2>/dev/null | awk '/via/ {print $3; exit}')" "$servers")
    search=$(awk '/^(search|domain)/ {for (i = 2; i <= NF; i++) print $i}' /etc/resolv.conf 2>/dev/null | sort -u | paste -sd, - | sed 's/,/, /g')
  fi
  if [ -n "$rows" ]; then
    # Normal lookups follow the default route, so that interface goes first
    { printf 'Interface\tDefaultGateway\tDnsServers\n'; printf '%s\n' "$rows" | sort -s -k1,1 | cut -f2-; } | table
  else
    echo "  (no connected interface has DNS servers configured)"
  fi
  echo "Search suffixes: ${search:-(none)}"
}

run() {
  local hidden=""
  ip_and_mac
  host_info
  os_info
  if [ $INTERFACES -eq 1 ]; then interfaces; else hidden="-i (all interfaces and IP addresses)"; fi
  if [ $ROUTES -eq 1 ]; then routes; else hidden="$hidden${hidden:+, }-r (routing table)"; fi
  dns_in_use
  [ -n "$hidden" ] && printf '\n(more detail available: add %s)\n' "$hidden"
  return 0
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
