---
name: locking-ai-traffic-to-vpn
description: Use when setting up a new macOS machine so Claude/OpenAI/AI-service traffic can only egress via a designated WireGuard tunnel and must fail closed (no direct fallback, no node switching) when the tunnel or node dies — e.g. ban-prevention, censored networks, account-safety routing, "只走指定线路", "防止被封号"
---

# Locking AI Traffic to a VPN (fail-closed, zero client config)

## Overview

Force AI-service traffic (Anthropic, OpenAI, …) through one designated WireGuard tunnel while leaving all other apps untouched. When the tunnel or node dies, those connections must **fail, never fall back to direct** (封号线). Clients need zero proxy config — everything happens at the routing + packet-filter layer. Pattern: **filtered `AllowedIPs` host-routes into utun + pf anchor that passes on utun and blocks the same destinations everywhere else**.

## When to Use / When NOT

- ✅ New machine; "只走指定线路"; ban-risk paranoia; verifying an inherited setup.
- ❌ You control the client and can set a proxy (use HTTPS_PROXY instead); you want a global VPN (just use `AllowedIPs = 0.0.0.0/0`).

## Decision Flow

```
Service has DEDICATED IP ranges? (Anthropic yes; OpenAI = Cloudflare anycast, no)
  yes → pin CIDRs statically, done (weekly re-check DNS anyway)
  no  → pin resolved /32s + run a sync daemon that re-resolves and reconciles
        pf table + wg allowed-ips + routes + config (IP rotation = the enemy)
```

## Architecture

```
Claude/OpenAI apps (no proxy settings at all)
   │  TCP/443 to api.anthropic.com / api.openai.com …
   ▼
routing: AllowedIPs pins Anthropic CIDRs + OpenAI /32s + tunnel DNS → utun8
   ▼
WireGuard tunnel ──▶ designated node ──▶ Internet
   ▲
pf anchor: pass out on utun8 to <locked>;  block return out to <locked>  ← fail-close
           (global block hits en0 only when the utun route is absent)
```

## Steps (scripts in `scripts/`, all read vars from `vars.conf`)

1. **Preflight (optional, 防封号 half)**: `scripts/00-preflight-verify.sh` — read-only residue scan (old account files, keychain incl. legacy/suffixed service names, npm/bun installs, shell rc, env). Clean first if residue.
2. **Configure**: copy `scripts/vars.conf.example` → `vars.conf`, fill in WG_CONF / PEER_PUBKEY / TUNNEL_DNS. Filter the wg conf's `AllowedIPs` (never leave `0.0.0.0/0` unless you *want* full-tunnel), keep `DNS = <tunnel DNS>` (DNS must reach the resolver through the tunnel).
3. **Apply**: `sudo scripts/10-apply-lock.sh` — backs up conf, rewrites AllowedIPs, installs `/etc/pf.anchors/ai.lock`, wires it into `/etc/pf.conf`, installs LaunchDaemons (pf enable at boot; IP-sync daemon), restarts tunnel, verifies normal path (`local_ip` = tunnel address; 401/404/421 all count as "reachable" — see Common Mistakes).
4. **Sync daemon** (`scripts/20-sync-ips.sh`, LaunchDaemon, default hourly): re-resolves the domain list (tunnel DNS first, DoH fallback), then atomically replaces the pf table (v4 pins + v6 block-only entries), rewrites `wg set allowed-ips` (v4 only), diffs routes, rewrites conf + anchor file. Never empties the table on resolution failure (fail-stale = fail-closed), kills pf states for removed IPs (`pfctl -k`).
5. **Verify** (`sudo scripts/30-failclosed-test.sh`): three proofs —
   - normal: curl returns via tunnel local IP;
   - tunnel down: curl **exit 7** (RST) — use `/etc/hosts` entries during the test so DNS can't mask the result; exit 28 is also fail-closed but weaker evidence;
   - node death: **remove the peer** (`wg set <iface> peer <key> remove`), expect SYN_SENT stuck on the tunnel IP + exit 28, then restore peer from conf via `wg addconf <FILE>` (file, not stdin!).

## Common Mistakes (all empirically bitten)

| Mistake | Reality / fix |
|---|---|
| Trusting AllowedIPs split-routing | It fails OPEN: tunnel down = routes deleted = direct. The pf anchor is the lock; routing alone is not. |
| `pfctl -a name -f -` as "temporary rule" | Orphan anchor — never evaluated unless the main ruleset has an `anchor`/`load anchor` line. |
| Table list `{ a,b,c, }` trailing comma / `tr '\n' ', '` for comma-space | BSD `tr` ignores the space (set-length mismatch) → pf syntax error → **rules silently not loaded**. Use space-separated entries. |
| pf block without `on` (or on wrong iface) | pf matches utun too — a bare `block` kills the tunnel path. Pattern: `pass out quick on $TUN_IF to <locked>` BEFORE a global `block return out quick to <locked>`. |
| Route-blackhole or port-flip to "kill the node" | wg-quick pre-installs an endpoint host route (`route add` → File exists), WG sockets cache routes, and commercial relays answer on ANY UDP port + initiate handshakes themselves → endpoint roaming undoes your change. Only **peer removal** (or key change) truly simulates node death. |
| `wg addconf` with a pipe on BSD/macOS | Needs a **file** argument. `wg addconf if <(sed …)` fails; write a temp file. |
| launchd job calling `wg`/`dig` from brew | LaunchDaemon PATH lacks `/opt/homebrew/bin` → "command not found". `export PATH=…` at script top. |
| Testing through system DNS while tunnel down | Tunnel DNS dies with the tunnel → curl exit 6/28 masks the pf result. Pin `/etc/hosts` entries for the test domains. |
| Expecting 200 = "works" | These endpoints return 401/403/404/421 at the edge — all mean **reachable**. Judge by `local_ip`/route, not status code. |
| pf statefulness | `block` doesn't kill existing states. On down/sync, `pfctl -k <ip>` (script does this). |
| Rotated-in unknown IP (anycast services) | Window where a brand-new IP isn't in table/route → attempts direct (censored nets block it anyway). Shrink with frequent sync + DoH fallback; only full-tunnel eliminates it. |
| App half-works: REST/API fine, UI stuck "Reconnecting" | You pinned only part of the host surface. ChatGPT desktop dot: REST = `chatgpt.com/backend-api` (worked all along), realtime pubsub = `wss://ws.chatgpt.com` (unpinned → dead → banner). Full host surface lives in the bundle: `strings /Applications/ChatGPT.app/Contents/Resources/app.asar \| grep -oE '[a-z0-9.-]+\.(openai\.com\|oaistatic\.com\|oaiusercontent\.com\|chatgpt\.com\|chatgpt\.site\|chatgpt-team\.site)'`. Pin every subdomain — apex ≠ subdomain on Cloudflare (e.g. `chatgpt.site` 104.18.17.199 ≠ `assets.chatgpt.site`). For the agent "dot": `codex-cloud-backend.chatgpt.com` + `codex-cloud-environments.chatgpt.com`; voice: `realtime.chatgpt.com`; content: `persistent/cdn/auth-cdn/updates.oaistatic.com`; files/sandbox: `files/web-sandbox.oaiusercontent.com`; `chatgpt.site`/`chatgpt-team.site` appear in the app's scoped-UA list. Find missing hosts by SNI capture on the ACTIVE interface: `sudo tcpdump -i <iface> -s 0 tcp port 443`, grep for `server_name` strings. |
| `lsof` on the main app shows "no connection attempts" | Electron apps spawn helpers that own the sockets — inventory the whole bundle (`pgrep -fl /Applications/<App>.app`), then lsof every helper PID (ChatGPT desktop: `Codex (Service)`, `Codex (Renderer)`, `codex` CLI, `cua_node`). Sampling only the main PID sees a fraction of the traffic. |
| pf block list missing the ACTIVE interface | The active iface may be Ethernet `en12`, not `en0` — check `route get default` / `ifconfig`. Any unlisted physical iface is a fail-open hole for rotated-in IPs. Keep the anchor's `on { ... }` list matched to the interfaces actually in use. |
| "Toggling some other VPN fixes it" | Coincidence — the toggle only fires a macOS network-change event that un-latches the app's stuck reconnect. The path was never the fix. Bouncing the pinned tunnel (`wg-quick down/up`) pokes the same event while keeping traffic on the designated node. Find the real missing host instead. |
| Debugging from packets alone | Read the app's own logs first. ChatGPT/Codex desktop: `~/Library/Logs/com.openai.codex/**/*.log` (pubsub retry/backoff/exhausted lines), and Sentry breadcrumbs at `~/Library/Application Support/Codex/sentry/scope_v3.json` record exact failing request URLs. Caveat: some transport errors (e.g. `chatgpt_pubsub_transport_closed`) fire even in healthy states — diff across time windows before trusting them as the cause. |
| wg-quick DNS restore after network switch | Saved DNS is stale after switching networks → resolution oddities on tunnel-down. Fix: `sudo wg-quick down … && sudo ipconfig set en0 DHCP`. |

## Rollback

`sudo scripts/90-rollback.sh` — unloads LaunchDaemons, flushes the anchor, removes pf.conf lines + anchor file, restores the conf backup, restarts tunnel. Clients unaffected (they never knew).

## File Map

- `scripts/vars.conf.example` — every machine-specific value, one place.
- `scripts/00-preflight-verify.sh` — read-only; exit 1 on residue.
- `scripts/10-apply-lock.sh` — one-shot installer (idempotent).
- `scripts/20-sync-ips.sh` — reconcile daemon body (also runnable by hand).
- `scripts/30-failclosed-test.sh` — the three proofs.
- `scripts/90-rollback.sh` — full reversal.
