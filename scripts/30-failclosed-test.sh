#!/bin/bash
# 30-failclosed-test.sh — the three proofs. Usage: sudo 30-failclosed-test.sh
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/vars.conf"
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
pass=0; fail=0
check() { # $1 label, $2 expected-substr, $3 actual
  if echo "$3" | grep -q "$2"; then echo "  PASS  $1"; pass=$((pass+1)); else echo "  FAIL  $1  [$3]"; fail=$((fail+1)); fi
}

step() { printf '\n== %s ==\n' "$*"; }
step "proof 1: normal path goes via tunnel"
r=$(curl -sS -m 12 -o /dev/null -w '%{local_ip}' https://api.anthropic.com/ 2>&1)
check "anthropic via tunnel" "10\." "$r"
r=$(curl -sS -m 12 -o /dev/null -w '%{local_ip}' https://api.openai.com/ 2>&1)
check "openai via tunnel" "10\." "$r"

step "proof 2: tunnel DOWN = RST, never direct (DNS bypassed via /etc/hosts)"
A_IP=$(dig +short +time=3 +tries=1 A api.anthropic.com "@$TUNNEL_DNS" 2>/dev/null | grep -E '^[0-9]' | head -1)
O_IP=$(dig +short +time=3 +tries=1 A api.openai.com "@$TUNNEL_DNS" 2>/dev/null | grep -E '^[0-9]' | head -1)
echo "$A_IP api.anthropic.com" >> /etc/hosts
echo "$O_IP api.openai.com"     >> /etc/hosts
wg-quick down "$WG_CONF" >/dev/null 2>&1
a=$(curl -sS -m 8 -o /dev/null https://api.anthropic.com/ 2>&1); ra=$?
o=$(curl -sS -m 8 -o /dev/null https://api.openai.com/ 2>&1);    ro=$?
check "anthropic refused" "rc=7\|refused\|Couldn't connect" "rc=$ra $a"
check "openai refused"    "rc=7\|refused\|Couldn't connect" "rc=$ro $o"
wg-quick up "$WG_CONF" >/dev/null 2>&1
sed -i '' '/ api\.anthropic\.com$/d;/ api\.openai\.com$/d' /etc/hosts
sleep 8
r=$(curl -sS -m 12 -o /dev/null -w '%{local_ip}' https://api.anthropic.com/ 2>&1)
check "restored via tunnel" "10\." "$r"

step "proof 3: node death = SYN stuck inside tunnel (peer removal — the ONLY valid simulation)"
TMPF=$(mktemp /tmp/wg-peer.XXXXXX); trap 'rm -f "$TMPF"' EXIT
sed -n '/^\[Peer\]/,$p' "$WG_CONF" > "$TMPF"   # BSD wg addconf needs a FILE, not stdin
wg set "$IFACE" peer "$PEER_PUBKEY" remove
echo "$A_IP api.anthropic.com" >> /etc/hosts
curl -sS -m 15 -o /dev/null https://api.anthropic.com/ 2>/dev/null & cpid=$!
sleep 6
state=$(lsof -a -nP -iTCP -p "$cpid" 2>/dev/null | tail -1)
check "SYN_SENT on tunnel addr" "SYN_SENT.*10\." "$state"
wait "$cpid"; rc=$?
check "curl times out (exit 28)" "rc=28" "rc=$rc"
echo "-- routes unchanged (no path switching) --"
netstat -rn -f inet | grep "$A_IP" | head -3
wg addconf "$IFACE" "$TMPF"   # restore peer from file
sed -i '' '/ api\.anthropic\.com$/d' /etc/hosts
sleep 8
r=$(curl -sS -m 12 -o /dev/null -w '%{local_ip}' https://api.anthropic.com/ 2>&1)
check "restored via tunnel" "10\." "$r"

echo
echo "passed=$pass failed=$fail"
[ $fail -eq 0 ]
