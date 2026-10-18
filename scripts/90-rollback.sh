#!/bin/bash
# 90-rollback.sh — full reversal of 10-apply-lock.sh. Usage: sudo 90-rollback.sh
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/vars.conf"
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

launchctl unload /Library/LaunchDaemons/local.ai.lock.pf.plist 2>/dev/null
launchctl unload /Library/LaunchDaemons/local.ai.lock.sync.plist 2>/dev/null
rm -f /Library/LaunchDaemons/local.ai.lock.pf.plist /Library/LaunchDaemons/local.ai.lock.sync.plist
pfctl -a ai.lock -F rules 2>/dev/null
sed -i '' '/ai\.lock/d' /etc/pf.conf
rm -f /etc/pf.anchors/ai.lock
pfctl -f /etc/pf.conf 2>/dev/null
[ -f "$WG_CONF.bak-ailock" ] && cp "$WG_CONF.bak-ailock" "$WG_CONF" && echo "conf restored from .bak-ailock"
wg-quick down "$WG_CONF" >/dev/null 2>&1
wg-quick up "$WG_CONF" 2>&1 | tail -1
echo "rolled back. Direct-egress behavior restored; AI traffic no longer locked."
