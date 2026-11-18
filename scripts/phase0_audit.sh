#!/bin/bash
# NetScope Pro — Phase 0 environment audit (READ-ONLY).
#
# Usage:  ./scripts/phase0_audit.sh [--with-speedtest] [--privacy] > audit.txt
#
# This script never modifies any system setting. It only reads information.
#   --with-speedtest  also runs one `networkQuality -c` (consumes data: typically several hundred MB
#                     on a fast link).
#   --privacy         masks IP/MAC addresses and SSIDs in the output.
set -u
WITH_SPEEDTEST=0
PRIVACY=0
for a in "$@"; do
  case "$a" in
    --with-speedtest) WITH_SPEEDTEST=1 ;;
    --privacy) PRIVACY=1 ;;
  esac
done

mask() {
  if [ "$PRIVACY" = "1" ]; then
    sed -E -e 's/([0-9]{1,3}\.){3}[0-9]{1,3}/x.x.x.x/g' \
           -e 's/([0-9a-fA-F]{1,2}:){5}[0-9a-fA-F]{1,2}/xx:xx:xx:xx:xx:xx/g' \
           -e 's/(SSID[^:]*:).*/\1 <masqué>/g'
  else
    cat
  fi
}

section() { printf '\n===== %s =====\n' "$1"; }
have() { [ -x "$1" ] && echo "OK      $1" || echo "ABSENT  $1"; }

section "Système"
sw_vers 2>/dev/null
echo "Architecture : $(uname -m)"
sysctl -n machdep.cpu.brand_string 2>/dev/null
echo "Apple Silicon : $( [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ] && echo oui || echo non)"
sysctl -n hw.model 2>/dev/null

section "Outils de développement"
xcode-select -p 2>/dev/null || echo "xcode-select : aucun chemin"
xcodebuild -version 2>/dev/null || echo "xcodebuild indisponible (Xcode non installé ?)"
swift --version 2>/dev/null | head -2 || echo "swift indisponible"
xcrun --show-sdk-version 2>/dev/null && xcrun --show-sdk-path 2>/dev/null
xcodebuild -showsdks 2>/dev/null | grep -i macos
command -v xcodegen >/dev/null && echo "xcodegen : $(xcodegen --version 2>/dev/null)" || echo "xcodegen : absent (optionnel)"
command -v brew >/dev/null && echo "Homebrew : présent" || echo "Homebrew : absent (optionnel)"

section "Commandes système utilisées par NetScope"
for t in /usr/bin/networkQuality /sbin/ping /sbin/ping6 /usr/sbin/traceroute /usr/sbin/netstat /usr/sbin/arp \
         /usr/sbin/ndp /usr/sbin/scutil /usr/sbin/networksetup /sbin/ifconfig /sbin/route /usr/sbin/ipconfig \
         /usr/bin/nettop /usr/sbin/system_profiler /opt/homebrew/bin/iperf3 /usr/local/bin/iperf3; do
  have "$t"
done

section "networkQuality : options prises en charge"
/usr/bin/networkQuality -h 2>&1 | head -40

section "Interfaces matérielles"
networksetup -listallhardwareports 2>/dev/null | mask

section "Ordre des services"
networksetup -listnetworkserviceorder 2>/dev/null | mask

section "ifconfig"
ifconfig -a 2>/dev/null | mask

section "Routes"
netstat -rn 2>/dev/null | head -40 | mask

section "DNS (scutil --dns)"
scutil --dns 2>/dev/null | head -60 | mask

section "Proxy (scutil --proxy)"
scutil --proxy 2>/dev/null | mask

section "Réseau principal (scutil --nwi)"
scutil --nwi 2>/dev/null | mask

section "VPN (scutil --nc list)"
scutil --nc list 2>/dev/null | mask

section "Wi-Fi (system_profiler SPAirPortDataType)"
system_profiler SPAirPortDataType 2>/dev/null | head -60 | mask
echo "Remarque : depuis macOS 14.4, SSID/BSSID nécessitent l’autorisation de localisation pour l’app qui les lit."

section "Cache ARP / voisins"
arp -an 2>/dev/null | head -30 | mask
ndp -an 2>/dev/null | head -15 | mask

section "nettop (échantillon par processus)"
nettop -P -x -L 1 -J bytes_in,bytes_out 2>&1 | head -15

section "Connectivité"
GW=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')
echo "Passerelle par défaut : $(echo "$GW" | mask)"
[ -n "$GW" ] && ping -c 3 -W 1000 "$GW" 2>&1 | tail -3 | mask
ping -c 3 -W 1000 1.1.1.1 2>&1 | tail -3
echo "Résolution DNS (dscacheutil) :"
dscacheutil -q host -a name apple.com 2>/dev/null | head -4

if [ "$WITH_SPEEDTEST" = "1" ]; then
  section "networkQuality -c (consomme des données)"
  /usr/bin/networkQuality -c 2>&1 | mask
fi

section "Fin de l’audit (aucune modification effectuée)"
