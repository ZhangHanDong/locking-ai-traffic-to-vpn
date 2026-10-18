#!/bin/bash
# 00-preflight-verify.sh — read-only Claude/OpenAI account-residue scan (exit 1 on hits)
# Sources vars.conf from the same directory as this script.
DIR="$(cd "$(dirname "$0")" && pwd)"; [ -f "$DIR/vars.conf" ] && . "$DIR/vars.conf"
residue=0; hit() { echo "  ✗ $1"; residue=1; }; ok() { echo "  ✓ $1"; }

echo '== home =='
[ -e "$HOME/.claude" ] && hit "~/.claude" || ok "no ~/.claude"
ls "$HOME"/.claude.json* >/dev/null 2>&1 && hit "~/.claude.json*" || ok "no ~/.claude.json*"
[ -e "$HOME/.local/share/claude" ] && hit "~/.local/share/claude" || ok "no native CLI dir"
[ -e "$HOME/ClaudeBackups" ] && hit "~/ClaudeBackups" || ok "no ClaudeBackups"

echo '== desktop data roots =='
for d in "Claude" "Claude-3p" "com.anthropic.claudefordesktop"; do
  [ -e "$HOME/Library/Application Support/$d" ] && hit "AppSupport/$d" || ok "no $d"
done

echo '== library traces =='
ls -d "$HOME"/Library/Caches/claude-cli-nodejs "$HOME"/Library/Caches/com.anthropic.* >/dev/null 2>&1 && hit "Caches" || ok "Caches clean"
[ -e "$HOME/Library/Logs/Claude" ] && hit "Logs/Claude" || ok "no Logs/Claude"
ls "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | grep -qE '^Claude([ ._-]|$)' && hit "DiagnosticReports" || ok "no crash reports"
ls "$HOME/Library/Application Support/CrashReporter" 2>/dev/null | grep -qE '^Claude([ ._-]|$)' && hit "CrashReporter" || ok "no CrashReporter"
ls -d "$HOME"/Library/HTTPStorages/com.anthropic.* "$HOME"/Library/WebKit/com.anthropic.* "$HOME"/Library/Saved\ Application\ State/com.anthropic.* >/dev/null 2>&1 && hit "HTTP/WebKit/SavedState" || ok "HTTP/WebKit/SavedState clean"
ls "$HOME/Library/Preferences" "$HOME/Library/Preferences/ByHost" 2>/dev/null | grep -q 'com.anthropic' && hit "Preferences plists" || ok "Preferences clean"

echo '== keychain (incl. legacy "Claude Code" + suffixed variants) =='
kc=$(security dump-keychain 2>/dev/null | grep -i -E '"svce"<blob>="[^"]*claude[^"]*"' | sort -u)
[ -n "$kc" ] && hit "keychain: $kc" || ok "keychain clean"

echo '== CLI install sources =='
found=0
for p in /opt/homebrew/lib/node_modules/@anthropic-ai /usr/local/lib/node_modules/@anthropic-ai "$HOME"/.nvm/versions/node/*/lib/node_modules/@anthropic-ai "$HOME"/.bun/install/global/node_modules/@anthropic-ai; do
  [ -e "$p" ] && { hit "npm/bun: $p"; found=1; }
done
[ $found -eq 0 ] && ok "no npm/nvm/bun globals"

echo '== shell rc / npmrc / gitconfig =='
r=$(grep -l -E 'ANTHROPIC|CLAUDE_CODE_OAUTH|apiKeyHelper' "$HOME"/.zshrc "$HOME"/.zshenv "$HOME"/.zprofile "$HOME"/.bashrc "$HOME"/.bash_profile "$HOME"/.profile 2>/dev/null)
[ -n "$r" ] && hit "rc files: $r" || ok "rc files clean"
grep -qiE 'proxy' "$HOME"/.npmrc "$HOME"/.gitconfig 2>/dev/null && hit ".npmrc/.gitconfig proxy" || ok ".npmrc/.gitconfig clean"

echo '== env =='
[ -n "$(env | grep -E '^(CLAUDE|ANTHROPIC)')" ] && hit "shell env" || ok "shell env clean"
gui=0
for v in CLAUDE_CONFIG_DIR CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL HTTP_PROXY HTTPS_PROXY; do
  [ -n "$(launchctl getenv "$v" 2>/dev/null)" ] && { hit "GUI env: $v"; gui=1; }
done
[ $gui -eq 0 ] && ok "GUI env clean"

echo '== processes =='
pgrep -fl -i 'claude' >/dev/null && hit "claude processes running" || ok "no claude processes"

echo
if [ $residue -eq 0 ]; then echo 'CLEAN — safe to sign in a fresh account'; else echo 'RESIDUE FOUND — back up, then remove the ✗ items'; fi
exit $residue
