# project-net

Per-project WireGuard gateway (fail-closed) for Qubes OS.

## Table of Contents

*   [Description](#description)
*   [Installation](#installation)
*   [Supplying the WireGuard config](#supplying-the-wireguard-config)
*   [Usage](#usage)
*   [Verification](#verification)
*   [Multiple project networks](#multiple-project-networks)
*   [Notes and limitations](#notes-and-limitations)

## Description

Creates `sys-project-net`, a dedicated ProxyVM that carries one project's
traffic through a WireGuard tunnel. Any provider or peer that emits a
standard wg-quick conf works — Mullvad, a self-hosted peer, a company VPN.

Unlike [templates/vpn](../vpn/) (generic, fail-open, iptables/Fedora), this
unit is Debian + nftables and **fail-closed**:

*   Downstream qubes' traffic is only ever forwarded into `wg0`. If the
    tunnel is down (or no config is present yet), traffic is dropped — it
    never falls back to the clearnet path through sys-firewall.
*   The gateway's own clearnet egress is restricted to the WireGuard
    handshake (the `Endpoint` ip:port parsed from `wg0.conf`).
*   Downstream DNS (the Qubes virtual nameservers 10.139.1.1/.2) is DNAT'd to
    the tunnel resolver from the conf's `DNS=` line (fallback `9.9.9.9`,
    still routed through the tunnel) — no DNS leak to the upstream resolvers.

The firewall lives in a marker-merged `# >>> project-net >>>` block of
`/rw/config/qubes-firewall-user-script` and owns the whole
`inet project-net` nft table (replaced atomically on every boot).
`/rw/config/rc.local` brings the tunnel up afterwards.

Topology:

```
Internet <-> sys-net <-> sys-firewall <-> sys-project-net <-> project qubes
                                          (WireGuard, fail-closed)
```

## Installation

Deploy order matters: **finish this unit (including the wg0.conf) before
starting any qube that uses it as netvm** — until `configure` has run inside
sys-project-net, the fail-closed firewall does not exist yet.

```sh
# 1. Create qubes + install packages + configure
sudo qubesctl top.enable templates.project-net
sudo qubesctl state.apply templates.project-net.create
sudo qubesctl --skip-dom0 --targets=tpl-project-net state.apply templates.project-net.install
sudo qubesctl --skip-dom0 --targets=sys-project-net state.apply templates.project-net.configure
sudo qubesctl top.disable templates.project-net

# 2. Supply the WireGuard config (next section), then restart the gateway
qvm-shutdown --wait sys-project-net && qvm-start sys-project-net
```

## Supplying the WireGuard config

The tunnel credential is a secret and is deliberately not salt-managed.
For Mullvad: download a config from
<https://mullvad.net/en/account/wireguard-config> (pick a hostname-free
config — the default; endpoints are IP literals).

```sh
# From the qube that has the conf:
qvm-copy-to-vm sys-project-net wg0.conf

# Inside sys-project-net:
sudo mv /home/user/QubesIncoming/*/wg0.conf /rw/config/wireguard/wg0.conf
sudo chmod 600 /rw/config/wireguard/wg0.conf
```

`/rw` persists across reboots; do **not** use `/etc/wireguard` — that path is
reset with the root volume on every AppVM boot.

Requirements for the conf:

*   `Endpoint` must be an **IPv4 literal** (`1.2.3.4:51820`). A hostname
    cannot resolve before the tunnel exists under the kill-switch, so it is
    treated as "no endpoint" and the gateway stays fully closed.
*   `DNS =` should be set (Mullvad configs always set it). Without it,
    downstream DNS is sent to `9.9.9.9` through the tunnel.

## Usage

Attach the project's qubes:

```sh
qvm-prefs my-project-qube netvm sys-project-net
```

The [templates/ai](../ai/) unit does this declaratively for the `ai` qube.

## Verification

```sh
# Inside sys-project-net:
sudo wg show                                  # handshake present?
sudo nft list table inet project-net          # kill-switch loaded?
sudo journalctl -t project-net                # boot-time wg-quick output

# Inside a downstream qube (Mullvad):
curl https://am.i.mullvad.net/connected
# Kill-switch test: in sys-project-net `sudo wg-quick down ...`, then the
# downstream curl must HANG/FAIL — never fall back to your real IP.
```

## Multiple project networks

Every qube name derives from this unit's directory name. For another isolated
project network, copy the whole directory:

```sh
cp -r salt/templates/project-net salt/templates/acme-net
```

then edit the **five .top files** in the copy by hand — tops cannot use
slsdotpath, and **both** things they hardcode must change:

*   every state path: `templates.project-net.<state>` →
    `templates.acme-net.<state>` (all five files);
*   the target qube names `tpl-project-net` / `sys-project-net` →
    `tpl-acme-net` / `sys-acme-net` (install.top, configure.top, init.top).

If you only change the qube names, the copy's tops still apply
**this** unit's states — you'd silently re-create tpl-/sys-project-net and
never get the acme qubes. Then rerun `scripts/setup.sh` and apply. You get
`sys-acme-net` with its own wg0.conf — e.g. a different Mullvad exit, or a
different provider entirely.

## Notes and limitations

*   WireGuard only. For OpenVPN use [templates/vpn](../vpn/) (fail-open!).
*   The fail-closed **base** policy is baked into the template
    (`/etc/project-net/base.nft`, loaded at boot by
    `project-net-fail-closed.service`): even a freshly created,
    never-configured sys-project-net drops downstream traffic instead of
    routing it clearnet. Any qube built from tpl-project-net behaves this
    way — that is the point of this template; don't base ordinary AppVMs
    on it.
*   Downstream qubes should keep the default (allow-all) Qubes firewall.
    A restrictive per-qube policy's "Allow DNS" rule matches the Qubes
    virtual nameservers, but this gateway rewrites downstream :53 to the
    tunnel resolver *before* those rules are evaluated — so with a
    default-deny per-qube policy, add an explicit allow for the conf's
    `DNS=` address (or 9.9.9.9) or DNS goes dark for that qube
    (fail-closed, not a leak).
*   IPv6: downstream v6 is fail-closed too (dropped unless it can go through
    the tunnel); the tunnel itself is used v4-only by this unit.
*   `openresolv` is installed because `wg-quick` aborts on confs carrying
    `DNS=` when no `resolvconf` binary exists.
*   While the tunnel is up, the gateway's own `/etc/resolv.conf` points at
    the tunnel DNS; after `wg-quick down` the gateway itself may lose DNS
    until reboot — downstream qubes are unaffected.

## Qubes Created

| Qube | Type | Description |
|------|------|-------------|
| tpl-project-net | Template | Debian minimal + wireguard-tools/nftables |
| sys-project-net | AppVM | Fail-closed WireGuard gateway (ProxyVM) |

## License

SPDX-License-Identifier: MIT

Copyright 2026 Chris Su
