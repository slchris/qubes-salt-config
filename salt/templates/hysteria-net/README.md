# hysteria-net

Per-project transparent **Hysteria2 (QUIC)** gateway for Qubes OS, built on
**sing-box**.

## Table of Contents

*   [Description](#description)
*   [When to use this](#when-to-use-this)
*   [Deploy](#deploy)
*   [Supplying the client config](#supplying-the-client-config)
*   [Usage](#usage)
*   [Verification](#verification)
*   [Multiple gateways](#multiple-gateways)
*   [Notes and limitations](#notes-and-limitations)

## Description

Creates `tpl-hysteria-net` and `sys-<key>` gateways (key = a `cfg.hysteria_nets`
entry; `"hysteria"` → `sys-hysteria`). Each is a ProxyVM that carries one
project's traffic through a **Hysteria2** tunnel: sing-box runs the Hysteria2
outbound over a userspace **gvisor tun**, and downstream TCP is simply
**forwarded** into that tun — the same forwarding model as the WireGuard
gateway in `templates/project-net`.

**The crux: the tun address is the Qubes virtual-DNS subnet `10.139.1.0/30`.**
Downstream qubes already send DNS and `10.139.x` traffic to their netvm, and
Qubes routes their default traffic through the netvm too. By making the tun
that subnet, the gateway needs **no DNAT-to-local** (which Qubes' forward policy
drops) — packets are forwarded into `tun0` exactly like `project-net` forwards
into `wg0`. This is the design from <https://github.com/hexstore/qubes-proxy>.

Topology:

```
Internet <-> sys-net <-> sys-firewall <-> sys-hysteria <-> project qubes
                                          (sing-box: hysteria2 over gvisor tun)
```

Inside `sys-hysteria`: downstream traffic on a vif is routed (sing-box
`auto_route`, table 2022) into `tun0`; sing-box's gvisor stack accepts it and
sends it out the Hysteria2 (QUIC) outbound. DNS to `10.139.1.1/.2` is sniffed
and answered by sing-box's own DoH-over-tunnel resolver. A reply-path ip rule
(`to 10.137.0.0/16 lookup main`) keeps responses to downstream qubes on the vif
instead of being swallowed by the tun's default route.

**Fail-closed.** If sing-box is down or the tunnel is down, downstream traffic
is dropped (the tun is gone and Qubes' forward policy drops vif traffic) — it
never falls back to the clearnet path.

## When to use this

Use this instead of `templates/project-net` (WireGuard) when the Qubes host is
far from the exit — e.g. a machine in China exiting through a US host. On a
~200 ms RTT cross-border path a WireGuard/BBR tunnel typically collapses to a
few hundred KB/s per stream because TCP window growth cannot keep up; QUIC
(Hysteria2) keeps much higher per-stream throughput. Measured on the reference
deployment: ~0.5 MB/s (WireGuard) → ~3–5 MB/s (Hysteria2), same exit IP, no
leaks.

For a low-RTT path, WireGuard (`project-net`) is simpler and equally fast.

## Deploy

Order matters: **finish install + configure (and drop in `config.json`) before
starting any qube that uses the gateway as netvm.**

```sh
sudo qubesctl top.enable templates.hysteria-net
sudo qubesctl state.apply templates.hysteria-net.create
sudo qubesctl --skip-dom0 --targets=tpl-hysteria-net state.apply templates.hysteria-net.install
sudo qubesctl --skip-dom0 --targets=sys-hysteria state.apply templates.hysteria-net.configure
sudo qubesctl top.disable templates.hysteria-net
```

After editing `config.json` (see below), restart the gateway
(`qvm-shutdown --wait sys-hysteria && qvm-start sys-hysteria`) or re-apply the
`configure` state; the gateway is brought up from `/rw/config/rc.local`.

## Supplying the client config

The server credential is a secret and is deliberately not salt-managed. The
gateway's `configure` state creates a skeleton at
`/rw/config/hysteria-net/config.json` (mode 0600). Fill in the **hysteria2
outbound** — everything else (tun address, dns, route) must stay:

```json
"outbounds": [
  {"type": "hysteria2", "tag": "proxy",
   "server": "203.0.113.10", "server_port": 8443, "password": "<password>",
   "tls": {"enabled": true, "server_name": "lisa.hy", "insecure": true}},
  {"type": "direct", "tag": "direct"},
  {"type": "dns", "tag": "dnsout"}
]
```

Then:

```sh
sudo /rw/config/hysteria-net/start.sh --check     # validate
sudo /rw/config/hysteria-net/start.sh --prepare   # apply + start
```

Keep the tun `inet4_address` at `10.139.1.0/30` and the `dns`/`route` blocks
as shipped — downstream qubes depend on them.

## Usage

Attach the project's qubes:

```sh
qvm-prefs my-project-qube netvm sys-hysteria
```

## Verification

```sh
# Inside sys-hysteria:
ip link show tun0                                   # gvisor tun up
ip rule show | grep 8999                            # reply-path rule (10.137/16)
ip route show table 2022                            # default dev tun0
sudo tail /run/hysteria-net/singbox.log             # sing-box outbound lines
sudo tail /rw/config/hysteria-net/boot.log          # rc.local bring-up

# Inside a downstream qube:
curl -s https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(ip|colo)='  # exit IP
curl -s https://api.ipify.org                       # same exit IP
curl -s -o /dev/null -w '%{speed_download}\n' \
  'https://speed.cloudflare.com/__down?bytes=20000000'
# Kill-switch test: in sys-hysteria `/rw/config/hysteria-net/start.sh` then
# `pkill -f "sing-box run"`; downstream curl must HANG/FAIL, never leak.
```

DNS/IPv6 leak checks (from a downstream qube):

```sh
ip -6 addr show scope global          # no global v6 -> no v6 leak path
getent hosts example.com              # resolves through the tunnel DNS
curl -s https://www.cloudflare.com/cdn-cgi/trace | grep ip=   # exit matches
```

## Multiple gateways

Every gateway is one key in `cfg.hysteria_nets` (`salt/config.jinja`). The key
becomes the qube name `sys-<key>`. All gateways share `tpl-hysteria-net` and
the same setup, so there is no directory to copy and no top file to hand-edit.
Each gateway still needs its **own** `/rw/config/hysteria-net/config.json`.

```jinja
"hysteria_nets": {
  "hysteria": {},
  "hysteria-nyc": {"memory": 500},
},
```

Optional per-key overrides: `template`, `label`, `netvm`, `memory`, `maxmem`.
`cfg.hysteria_net.singbox_version` pins the sing-box release fetched into the
gateway.

## Notes and limitations

*   **QUIC only.** The server must be a Hysteria2 server.
*   **sing-box 1.9.x is pinned.** 1.10/1.11 builds segfault on start in this
    Debian/tmpfs VM (Go runtime vs kernel); 1.9.7 runs. Bump
    `cfg.hysteria_net.singbox_version` only after re-testing.
*   **The binary runs from /tmp, not /rw.** Executing the fetched binary
    straight from `/rw` segfaults; the start script copies it to `/tmp` first.
*   **Driven from `/rw/config/rc.local`, not a systemd unit.** In this
    deployment an AppVM's root can be a stale template clone that never picks
    up a changed unit, so the gateway is started from `/rw` (its own
    persistent layer) on every boot. That is also why the start script lives at
    `/rw/config/hysteria-net/start.sh`.
*   **Self-signed cert** is fine with `tls.insecure: true`; for a real cert set
    `insecure: false` and rely on the system CA. SNI must match the cert.
*   **DNS** is answered by sing-box's DoH resolver over the tunnel; downstream
    DNS never reaches the clearnet.
*   **IPv6** is fail-closed (the tunnel is used v4-only).
*   **Reply path.** `ip rule 8999: to 10.137.0.0/16 lookup main` is
    required — without it sing-box's table-2022 default route swallows replies
    to downstream qubes and nothing works.

## Qubes Created

| Qube | Type | Description |
|------|------|-------------|
| tpl-hysteria-net | Template | Debian minimal + sing-box, nftables |
| sys-hysteria (sys-<key>) | AppVM | Fail-closed Hysteria2 (QUIC) transparent gateway |

## License

SPDX-License-Identifier: MIT

Copyright 2026 Chris Su
