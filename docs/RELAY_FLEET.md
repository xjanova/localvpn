# Relay fleet — how traffic leaves the app, and how its cost is kept in check

LocalVPN moves three kinds of traffic. Only the last two cost money, so the
design keeps everything it can on the first path.

| Path | What | Who pays |
|---|---|---|
| **Direct P2P** | virtual-LAN packets and file chunks between members, after UDP hole punching (STUN on the P2P socket, LAN + public candidates, timed bursts) | nobody |
| **LAN relay** (`relay` role) | the same sealed packets when two members cannot punch (both behind symmetric NAT / CGNAT) | node egress |
| **Game exit** (`game` role) | traffic to game servers only, from Thailand through a rented VPS near the game region | node egress |
| **Full VPN** (`vpn` role) | all internet traffic through a country (WireGuard) — Pro only | node egress |

Rules that keep the bill flat:

1. A node never carries more than its plan's included transfer. The backend
   stops handing out tickets for a node before it reaches the limit
   (free/trial users first, Pro last), so there is no overage unless the admin
   turns it on.
2. Game exits forward only to the game CIDRs the admin lists. The node's
   firewall enforces it, not just the app's routes, so a modified client
   cannot turn a game exit into a free full VPN.
3. Every ticket carries the user's rate cap and daily cap. The node enforces
   both, and the backend adds up usage across nodes before issuing the next
   ticket.
4. The LAN relay only sees ciphertext (packets are sealed end to end by
   `P2pCrypto`); it routes by virtual IP inside one network and nothing else.

## Pieces

```
 app ──HTTPS──▶ xmanstudio (control plane)  ◀──HTTPS sync every 10 s── lvnode (each VPS)
  │              • heartbeat → relay ticket                              • LVR1 UDP relay
  │              • wireguard/register → exit config                      • WireGuard peers (game/vpn)
  │              • game-profiles → split-tunnel CIDRs                    • ipset of game CIDRs
  │              • admin: nodes, policy, budget, usage                   • usage + NIC counters
  └──UDP──▶ lvnode :51821 (LVR1)      └──WireGuard──▶ lvnode :51820
```

## LVR1 — UDP relay protocol (port 51821)

Every datagram starts with `4C 56 52 31` (`LVR1`) and one type byte.

| Dir | Type | Body |
|---|---|---|
| C→R | `01` register / keepalive | `cookie(8)` `token(utf-8)` |
| R→C | `07` cookie challenge | `cookie(8)` |
| R→C | `06` registered | `ttl_seconds(2)` |
| R→C | `05` refused | `reason(utf-8)`: `bad-token`, `expired`, `wrong-node`, `full`, `quota`, `rate` |
| C→R | `02` forward | `dst_vip(4)` `sealed P2P packet` |
| R→C | `02` delivered | `src_vip(4)` `sealed P2P packet` |

- **Cookie (return routability).** `cookie = HMAC-SHA256(node_secret, "c|" ip "|" port "|" bucket)[0..8]`,
  `bucket = floor(unix / 120)`; the current and the previous bucket are
  accepted. A register with a missing or stale cookie gets only a `07`
  (13 bytes, smaller than the request), so a forged source address can't
  register anything or be amplified.
- **Registration** binds `(network_id, vip)` to the sender's address. A newer
  registration of the same pair replaces the old address (NAT rebinding,
  phone switching networks). Idle registrations expire after 45 s; the
  client re-registers every 10 s.
- **Forwarding** looks the sender up by address, checks its ticket has not
  expired and its rate/daily budget, finds `(same network, dst_vip)` and
  sends `02 src_vip packet` there. Nothing else is touched. Frames over 1600
  bytes are dropped.
- The client accepts a relayed packet only if `src_vip` equals the sender
  virtual IP inside the sealed header, and only after `P2pCrypto.open`
  authenticated it. Relayed `hello`/`helloReply` prove the relay path; they
  never mark a peer direct or move its endpoint.

### Ticket (in the heartbeat answer)

```json
"relay": {
  "host": "203.0.113.10", "port": 51821, "node": "th-bkk-1",
  "token": "v1.<node_id>.<network_id>.<vip>.<exp>.<kbps>.<daily_mb>.<sig>",
  "expires_at": "2026-10-11T12:30:00Z"
}
```

`sig = hex(HMAC-SHA256(node_secret, "v1.<node_id>.<network_id>.<vip>.<exp>.<kbps>.<daily_mb>"))`.
`exp` is a unix time; the backend rounds it to 10-minute steps so the token
stays the same across heartbeats. `kbps = 0` / `daily_mb = 0` mean no cap.
The node refuses a token whose `node_id` is not its own. No `relay` key (or
`null`) means no relay is offered right now.

## Node sync — `POST /api/v1/localvpn/node/sync`

Headers: `X-Node-Id: <id>`, `X-Node-Time: <unix>`,
`X-Node-Signature: hex(HMAC-SHA256(node_secret, "<time>.<raw body>"))`.
The backend rejects a time more than 300 s off or not later than the last
accepted one from that node.

Request (usage counters are deltas since the previous accepted sync):

```json
{
  "agent": "lvnode/1.0.0", "roles": ["relay", "game"],
  "wg_public_key": "base64…", "wg_port": 51820, "relay_port": 51821,
  "nic": {"rx": 123, "tx": 456},
  "relay": {"clients": 12, "rx": 1000, "tx": 1000,
            "usage": [{"net": 12, "vip": "10.10.0.2", "bytes": 4096}]},
  "exit":  {"peers": 3, "usage": [{"pub": "base64…", "rx": 1, "tx": 2}]},
  "load1": 0.12
}
```

Response:

```json
{
  "ok": true, "status": "active",
  "sync_interval_s": 10,
  "budget": {"accept_new": true, "min_tier": "free", "used_gb": 120.5, "quota_gb": 1000},
  "relay": {"enabled": true, "max_clients": 2000},
  "exit": {
    "enabled": true, "mode": "game",
    "address": "10.66.0.1/24", "listen_port": 51820,
    "peers": [{"pub": "base64…", "ip": "10.66.0.5", "kbps": 0}],
    "allow_cidrs": ["43.229.64.0/18", "…"]
  }
}
```

- `exit.address` / `exit.listen_port` come from the node's linked
  `wireguard_servers` row; the node creates `wg0` with them and NATs that
  subnet out of its default interface. The node keeps its WireGuard private
  key on disk and only reports `wg_public_key`; the backend copies it (and
  `endpoint = host:wg_port`) into the linked row. Such rows store no private
  key.

- `status`: `active` | `draining` (keep current users, no new tickets) |
  `disabled` (relay refuses everything, WireGuard peers removed).
- `exit.mode`: `game` = forward only to `allow_cidrs`; `vpn` = full.
- The node replaces its WireGuard peer set with `exit.peers` on every sync.

## Backend: data and policy

- `vpn_nodes`: name, code (`th-bkk-1`), country, city, provider, host,
  relay_port, wg_port, wg_public_key, roles, status, secret (encrypted),
  monthly_cost_thb, included_gb, overage_thb_per_gb, billing_day,
  billing_mode (`out` | `in_out` | `max`), allow_overage, max_clients, weight,
  last_seen_at, last_sync (json).
- `vpn_node_usage_daily`: node, date, nic_rx, nic_tx, relay_bytes, exit_bytes, peak_clients.
- `vpn_user_usage_daily`: date, license_key_id (or machine_id), kind
  (`relay` | `exit`), bytes. Daily caps are checked against this.
- `vpn_game_profiles`: name, slug, region, cidrs (text), enabled, sort.
- Policy (setting `localvpn_fleet_policy`, JSON, edited in admin):

```json
{
  "tiers": {
    "free":  {"relay_kbps": 1500,  "relay_daily_mb": 300,   "game": false, "exit_daily_mb": 0},
    "trial": {"relay_kbps": 8000,  "relay_daily_mb": 3000,  "game": true,  "exit_daily_mb": 1500},
    "pro":   {"relay_kbps": 20000, "relay_daily_mb": 10000, "game": true,  "exit_daily_mb": 5000}
  },
  "budget": {"monthly_thb": 3000, "free_cut_pct": 80, "trial_cut_pct": 90, "pro_cut_pct": 98}
}
```

- Node budget = this billing month's NIC bytes (by `billing_mode`) against
  `included_gb`. At `free_cut_pct` the node stops taking free users, at
  `trial_cut_pct` trial users, at `pro_cut_pct` everyone (unless
  `allow_overage`). When the projected month cost of all nodes passes
  `budget.monthly_thb`, `allow_overage` is ignored everywhere.
- Relay ticket choice: nodes with the `relay` role, `active`, seen in the last
  60 s, accepting the user's tier, the user under their daily cap; prefer the
  node in the user's country, then lowest load / highest weight.

## Admin (xmanstudio → LocalVPN → Fleet)

- **Nodes**: list (status, roles, country, clients, month GB vs included,
  cost so far, projected cost, last seen), create/edit, rotate secret, copy
  install command.
- **Policy**: tier limits and budget thresholds form; game profiles CRUD.
- **Cost**: month-to-date cost and projection per node and total, GB per
  day chart, top users by relay/exit bytes.

## Installing a node (owner, with sudo)

```bash
curl -fsSL https://xman4289.com/downloads/lvnode/install.sh -o install.sh
sudo bash install.sh --id <node id> --secret <secret> --roles relay,game
```

The script installs `/usr/local/bin/lvnode`, WireGuard and ipset, writes
`/etc/lvnode.env`, sets up `wg0` with NAT on the default interface (detected,
not hard-coded `eth0`), opens UDP 51820/51821 and starts `lvnode.service`.
