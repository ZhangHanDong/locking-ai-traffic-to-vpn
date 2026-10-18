#!/bin/bash
# 10-apply-lock.sh — one-shot installer (idempotent). Usage: sudo 10-apply-lock.sh
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/vars.conf"
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
ANCHOR=/etc/pf.anchors/ai.lock
SYNC="$DIR/20-sync-ips.sh"
step() { printf '\n== %s ==\n' "$*"; }

step "backup"
cp "$WG_CONF" "$WG_CONF.bak-ailock" && echo "-> $WG_CONF.bak-ailock"

step "resolve domain /32s (tunnel DNS, system fallback)"
IPS=""
for d in $DOMAINS; do
  r=$(dig +short +time=3 +tries=1 A "$d" "@$TUNNEL_DNS" 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u)
  [ -z "$r" ] && r=$(dig +short +time=3 +tries=1 A "$d" 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u)
  IPS="$IPS $r"
done
IPS=$(echo "$IPS" | tr ' ' '\n' | grep -E '^[0-9]' | sort -u)
[ -z "$IPS" ] && { echo "resolution failed"; exit 1; }
echo "$IPS" | tr '\n' ' '; echo

step "filter AllowedIPs in $WG_CONF"
ALLOWED=""
for c in $STATIC_CIDRS; do ALLOWED="$ALLOWED,$c"; done
ALLOWED="${ALLOWED#,},$TUNNEL_DNS,$(echo "$IPS" | sed 's|$|/32|' | paste -sd, -)"
sed -i '' "s|^AllowedIPs = .*|AllowedIPs = $ALLOWED|" "$WG_CONF"
grep '^AllowedIPs' "$WG_CONF" | cut -c1-140; echo '  …'

step "install pf anchor (pass on $IFACE, block everywhere else)"
{
  echo "table <locked> persist { $(echo "$STATIC_CIDRS" | tr '\n' ' ') $(echo "$IPS" | tr '\n' ' ') }"
  echo "pass  out quick on $IFACE proto tcp to <locked>"
  echo "pass  out quick on $IFACE proto udp to <locked> port 443"
  echo "block return out quick proto tcp to <locked>"
  echo "block drop   out quick proto udp to <locked> port 443"
} > "$ANCHOR"
chmod 644 "$ANCHOR"
grep -q 'anchor "ai.lock"' /etc/pf.conf || printf '\nanchor "ai.lock"\nload anchor "ai.lock" from "/etc/pf.anchors/ai.lock"\n' >> /etc/pf.conf
pfctl -ef /etc/pf.conf 2>&1 | grep -viE 'ALTQ|Use of -f|flushing|startup|See /etc' || true
pfctl -a ai.lock -s rules

step "install LaunchDaemons (pf at boot + sync daemon)"
cat > /Library/LaunchDaemons/local.ai.lock.pf.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.ai.lock.pf</string>
  <key>ProgramArguments</key><array><string>/sbin/pfctl</string><string>-e</string><string>-f</string><string>/etc/pf.conf</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
EOF
cat > /Library/LaunchDaemons/local.ai.lock.sync.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.ai.lock.sync</string>
  <key>ProgramArguments</key><array><string>$SYNC</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>${SYNC_INTERVAL:-3600}</integer>
  <key>StandardOutPath</key><string>/var/log/ai-lock-sync.log</string>
  <key>StandardErrorPath</key><string>/var/log/ai-lock-sync.log</string>
</dict></plist>
EOF
chmod 644 /Library/LaunchDaemons/local.ai.lock.*.plist
launchctl unload /Library/LaunchDaemons/local.ai.lock.pf.plist 2>/dev/null; launchctl load -w /Library/LaunchDaemons/local.ai.lock.pf.plist
launchctl unload /Library/LaunchDaemons/local.ai.lock.sync.plist 2>/dev/null; launchctl load -w /Library/LaunchDaemons/local.ai.lock.sync.plist

step "restart tunnel + first sync"
wg-quick down "$WG_CONF" >/dev/null 2>&1
wg-quick up "$WG_CONF" 2>&1 | tail -1
sleep 2
"$SYNC" || true

step "normal-path verification"
firstip=$(echo "$IPS" | head -1)
echo "route $firstip -> $(route get "$firstip" | awk '/interface/{print $2}')  (want $IFACE)"
curl -sS -m 12 -o /dev/null -w 'api.anthropic.com: HTTP %{http_code} local=%{local_ip}  (want tunnel; 401/404=reachable)\n' https://api.anthropic.com/ 2>&1
curl -sS -m 12 -o /dev/null -w 'api.openai.com:    HTTP %{http_code} local=%{local_ip}\n' https://api.openai.com/ 2>&1
curl -sS -m 12 -o /dev/null -w 'control (baidu):   HTTP %{http_code} local=%{local_ip}  (want direct)\n' https://www.baidu.com/ 2>&1
echo
echo "next: sudo $DIR/30-failclosed-test.sh"
