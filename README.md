# locking-ai-traffic-to-vpn

Force AI-service traffic (Anthropic, OpenAI, …) on macOS through one designated WireGuard tunnel — and nowhere else. When the tunnel or the node dies, connections fail closed (RST/timeout) instead of falling back to a direct route. Zero client-side proxy config: the lock lives at the routing (filtered `AllowedIPs`) + packet-filter (pf anchor) layer.

让 macOS 上 AI 服务（Anthropic、OpenAI 等）的流量只能走指定的 WireGuard 隧道；隧道或节点失效时连接直接失败（fail-closed），绝不回落到直连。无需在客户端配置任何代理——锁定发生在路由层（过滤版 `AllowedIPs`）和包过滤层（pf 锚点）。

## Usage / 用法

Everything is documented in [SKILL.md](SKILL.md). Quick path:

1. Copy `scripts/vars.conf.example` → `scripts/vars.conf` and fill in your WireGuard values.
2. `sudo scripts/10-apply-lock.sh`
3. `sudo scripts/30-failclosed-test.sh` to prove fail-closed behavior.
4. `sudo scripts/90-rollback.sh` to remove everything.

## Contents / 内容

- `SKILL.md` — full guide: decision flow, architecture, common mistakes (each empirically bitten), rollback.
- `scripts/` — preflight residue scan, installer, IP-sync daemon, fail-closed test, rollback.

## Requirements / 要求

- macOS with WireGuard (`wireguard-tools`) and pf.
- A working WireGuard config managed by `wg-quick`.
