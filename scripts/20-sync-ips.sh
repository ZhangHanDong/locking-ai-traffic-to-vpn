#!/bin/bash
# 20-sync-ips.sh — reconcile pf table + wg allowed-ips + routes + conf + anchor with live DNS.
# Safe to run any time (idempotent). Exit 0 even when tunnel is down (keeps table = fail-closed).
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; [ -f "$DIR/vars.conf" ] && . "$DIR/vars.conf"
ANCHOR=/etc/pf.anchors/ai.lock
LOG="$(date '+%F %T')"

ifconfig "$IFACE" >/dev/null 2>&1 || { echo "$LOG tunnel down — keeping existing table (fail-closed)"; exit 0; }

# --- resolve: tunnel DNS first, DoH fallback (covers apps that use their own encrypted DNS) ---
IPS=""
for d in $DOMAINS; do
  r=$(dig +short +time=3 +tries=1 A "$d" "@$TUNNEL_DNS" 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u)
  [ -z "$r" ] && r=$(dig +short +time=3 +tries=1 A "$d" 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u)
  [ -z "$r" ] && r=$(curl -sm 4 -H 'accept: application/dns-json' "https://1.1.1.1/dns-query?name=$d&type=A" 2>/dev/null \
      | /usr/bin/python3 -c 'import json,sys
try:
  [print(a["data"]) for a in json.load(sys.stdin).get("Answer",[]) if a.get("type")==1]
except Exception: pass' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u)
  IPS="$IPS $r"
done
IPS=$(echo "$IPS" | tr ' ' '\n' | grep -E '^[0-9]' | sort -u)
if [ -z "$IPS" ]; then echo "$LOG resolution failed — keeping existing table (fail-closed)"; exit 0; fi

# --- AAAA: pf block-only. On v4-only tunnels v6 pins can't be routed; putting them in
# the table fails CLOSED on v6-capable networks instead of leaking direct when an app
# prefers an AAAA answer. Never enters wg allowed-ips or the route table.
V6=""
for d in $DOMAINS; do
  r=$(dig +short +time=3 +tries=1 AAAA "$d" "@$TUNNEL_DNS" 2>/dev/null | grep -E ':' | grep -v '%' | sort -u)
  [ -z "$r" ] && r=$(dig +short +time=3 +tries=1 AAAA "$d" 2>/dev/null | grep -E ':' | grep -v '%' | sort -u)
  V6="$V6 $r"
done
V6=$(echo "$V6" | tr ' ' '\n' | grep -E ':' | sort -u)

# --- pf table (replace; kill states of removed IPs — pf blocks don't kill existing flows) ---
OLD=$(pfctl -a ai.lock -t locked -T show 2>/dev/null | tr -d ' ' | grep -E '^[0-9]')
NEWLIST="$(echo "$STATIC_CIDRS" | tr '\n' ' ') $IPS $V6"
pfctl -a ai.lock -t locked -T replace $NEWLIST 2>/dev/null
for ip in $OLD; do
  case "$ip" in */*|*:*) continue ;; esac   # CIDRs and v6 addrs carry no per-IP route
  echo "$NEWLIST" | tr ' ' '\n' | grep -qx "$ip" || { pfctl -k "$ip" >/dev/null 2>&1; route delete -inet "$ip/32" 2>/dev/null; }
done

# --- wg allowed-ips (full replacement, includes static CIDRs + tunnel DNS) ---
ALLOWED=""
for c in $STATIC_CIDRS; do ALLOWED="$ALLOWED,$c"; done
ALLOWED="${ALLOWED#,},$TUNNEL_DNS,$(echo "$IPS" | sed 's|$|/32|' | paste -sd, -)"
wg set "$IFACE" peer "$PEER_PUBKEY" allowed-ips "$ALLOWED"

# --- routes for /32 pins ---
for ip in $IPS; do
  route get "$ip" 2>/dev/null | grep -q "interface: $IFACE" || route add -inet "$ip/32" -interface "$IFACE" 2>/dev/null
done

# --- persist: conf + anchor file stay the source of truth across wg-quick/pf reloads ---
sed -i '' "s|^AllowedIPs = .*|AllowedIPs = $ALLOWED|" "$WG_CONF"
sed -i '' "s|^table <locked>.*|table <locked> persist { $NEWLIST }|" "$ANCHOR"

# --- optional endpoint watchdog (relays that rotate entry IPs) ---
if [ -n "${ENDPOINT_HOST:-}" ]; then
  hs=$(wg show "$IFACE" latest-handshakes 2>/dev/null | awk -v p="$PEER_PUBKEY" '$1==p{print $2}')
  if [ -n "$hs" ] && [ $(( $(date +%s) - hs )) -gt 180 ]; then
    newip=$(dig +short +time=3 +tries=1 A "$ENDPOINT_HOST" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -1)
    [ -n "$newip" ] && wg set "$IFACE" peer "$PEER_PUBKEY" endpoint "$newip:${ENDPOINT_PORT}" && echo "$LOG endpoint -> $newip:${ENDPOINT_PORT}"
  fi
fi

echo "$LOG synced: $IPS"
