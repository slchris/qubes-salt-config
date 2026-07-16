<!--
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT
-->

# mgmt.tailscale — Tailscale remote access via self-hosted Headscale

Remote access into (and out of) this Qubes machine over a Tailscale mesh whose
**control plane is your own [Headscale](https://headscale.net) server**, not
Tailscale's SaaS. One dedicated **`sys-tailscale` ProxyVM** joins the tailnet and
acts as the gateway:

```
Internet ── sys-net ── sys-firewall ── sys-tailscale ── AppVMs
                                          │  (tailnet node, 100.x.y.z)
                                          ├─ exit node        (optional)
                                          ├─ subnet router    (optional)
                                          └─ sshd / Tailscale SSH  (SSH into Qubes)
```

This sits alongside `mgmt.remote-debug` (LAN SSH port-forward) and
`mgmt.remotevm` (Qubes Air relay). Over the tailnet it **replaces the fragile
SNAT/DNAT port-forward** in `mgmt.remote-debug.netfw` for remote SSH — you reach
the machine at its `100.x` address from anywhere, no LAN, no port-forward.

## What each role gives you

| Goal | How |
|---|---|
| **SSH into Qubes** | `ssh user@<sys-tailscale-100.x>` (mode `sshd`), or `--ssh` + Tailscale SSH. To reach a *different* AppVM, set its `netvm` to `sys-tailscale` and run sshd there too, or ssh-hop through the gateway. |
| **Reach internal services** | Point the service's qube `netvm` at `sys-tailscale`; it's reachable from the tailnet at the gateway (or advertise its subnet). |
| **Exit node / full tunnel** | `advertise_exit_node: True` → remote devices route all traffic out through this machine. |
| **Subnet router** | `advertise_routes: ["10.137.0.0/16", ...]` → expose a whole Qubes internal net to the tailnet. |

## Prerequisites — on your Headscale server

1. A reachable Headscale (target **0.29.x**) at an HTTPS URL, behind a
   **WebSocket-capable** reverse proxy (Caddy/nginx/Traefik — **not** Cloudflare
   proxy; the `/ts2021` control protocol needs WS upgrades). Ports: 443 (clients
   + embedded DERP), 3478/udp (STUN, if embedded DERP on), 80 (ACME only).
2. Create a user and a pre-auth key for the gateway:
   ```bash
   headscale users create qubes
   headscale users list                     # note the user id
   headscale preauthkeys create --user <ID> --reusable --expiration 720h
   ```
   (Default keys are single-use / 1-hour — override both for automation.)
3. Author policy as **HuJSON with grants** (v1 ACLs and YAML are removed in
   0.27/0.26). Remember usernames need an `@` (e.g. `qubes@`).

## Configure — `salt/config.jinja`, `cfg.tailscale`

```jinja
"enabled": True,
"login_server": "https://headscale.example.com",
"auth_key": "<preauthkey>",        # or leave "" and join interactively once
"advertise_exit_node": False,
"advertise_routes": [],            # e.g. ["10.137.0.0/16"]
"ssh": "sshd",                     # or "tailscale" / "none"
```

Leaving `auth_key: ""` keeps the secret out of git — you then complete a
one-time interactive login (see **Joining**). `authorized_keys: []` inherits your
YubiKey key from `cfg.remote_debug`.

## Deploy

All of this runs from **dom0** and edits nothing until `scripts/setup.sh` has
copied the repo into `/srv/salt/slchris`. So first:

```bash
sudo /path/to/qubes-salt-config/scripts/setup.sh     # or the deploy path into dom0
```

Then, **in order** (install → create → configure):

```bash
# 1. Install tailscaled in the template (goes out via update-proxy).
sudo qubesctl --skip-dom0 --targets=debian-13-minimal state.apply mgmt.tailscale.install

# 2. Create + wire the gateway qube (dom0).
sudo qubesctl top.enable mgmt.tailscale.create
sudo qubesctl state.apply mgmt.tailscale.create
sudo qubesctl top.disable mgmt.tailscale.create

# 3. Start it, then configure inside it (bind-dirs, firewall, join, sshd).
qvm-start sys-tailscale
sudo qubesctl --skip-dom0 --targets=sys-tailscale state.apply mgmt.tailscale.configure
```

Point a downstream AppVM through the tailnet gateway when you want it reachable /
tunneled:

```bash
qvm-prefs <appvm> netvm sys-tailscale
```

## Joining (interactive, when `auth_key` is "")

The `configure` state runs `tailscale up` regardless; on a fresh node with no key
it prints a registration URL. Grab it and register on the server:

```bash
qvm-run -p sys-tailscale 'sudo tailscale up --login-server https://headscale.example.com'
#   → prints:  https://headscale.example.com/register/<mkey>
headscale nodes register --user qubes --key <mkey>
headscale nodes expire --identifier <NODE_ID> --expiry 0     # don't expire the gateway
```

## Approving routes / exit node (Headscale side)

If you set `advertise_routes` / `advertise_exit_node`, approve them:

```bash
headscale nodes list-routes
headscale nodes approve-routes --identifier <NODE_ID> --routes 10.137.0.0/16,0.0.0.0/0,::/0
```

(The `headscale routes` subcommand was removed in 0.26 — use `nodes approve-routes`.)
For hands-off re-registers, tag the node and use `autoApprovers.routes` in policy.

## Teardown

```bash
sudo qubesctl top.enable mgmt.tailscale.teardown
sudo qubesctl state.apply mgmt.tailscale.teardown      # logs out + removes the qube
sudo qubesctl top.disable mgmt.tailscale.teardown
```

Repoint any downstream qube's `netvm` off `sys-tailscale` first, or it loses
network. Set `cfg.tailscale.keep_qube: True` to log out but keep the qube.

## Qubes-specific mechanics (why the states do what they do)

- **State persistence.** `/var/lib/tailscale` (node key/state) lives on the AppVM
  root volume, which is **wiped every reboot**. Without persistence the gateway
  re-registers as a *new* Headscale node each boot, orphaning entries. `install`
  puts tailscaled in the **template**; `configure` **bind-dirs** `/var/lib/tailscale`
  to `/rw` (persistent). Same pattern as `mgmt.remotevm.grpc-relay`.
- **TUN.** `/dev/net/tun` is present in a normal Qubes ProxyVM (full PV VM, not a
  container) → kernel-mode tailscaled, no `--tun=userspace-networking`.
- **Downstream DNS.** MagicDNS set in `sys-tailscale` does **not** reach AppVMs
  behind it, and `100.100.100.100` is a tailscaled-local VIP that is **not
  forwardable** — a raw DNAT of downstream `:53` to it black-holes. So `configure`
  runs a local **dnsmasq** on the gateway that forwards to `100.100.100.100`
  (queries it originates locally, which tailscaled answers), and nft-**REDIRECT**s
  downstream `:53` (aimed at the Qubes virtual NS `10.139.1.1/.2`) to that local
  resolver — marker-merged into `qubes-firewall-user-script` like `hotspot` /
  `remote-debug`, pure nftables (no iptables/PR-QBS; r4.3 is nftables-native).
  Toggle with `forward_downstream_dns`. Requires `accept_dns: True` so Quad100
  actually resolves.
- **Inbound SSH.** Qubes AppVMs drop inbound via an empty `custom-input`; the
  firewall script adds the `:22` accept (mode `sshd`).

## Version notes (early 2026)

- Headscale target **0.29.x**. Hard changes: policy v1 gone (0.27), YAML policy
  gone (0.26, use HuJSON + grants), usernames need `@`, `headscale routes` CLI
  gone (0.26). **Back up the SQLite DB before upgrading.**
- Tailscale client **≥1.80** (CVE-2025-22866) and **≥1.62** (Headscale ≥0.25 min
  capability). The template pulls current stable from the official repo.
- Tailscale SSH over Headscale has historically been the rough edge — prefer
  `ssh: "sshd"` until you've verified `--ssh` on your exact Headscale version.

## Security

`sys-tailscale` holds your tailnet identity/key and is networked — treat it as
sensitive, like the reused `mgmt-jump` relay. Prefer key-only sshd, scope
Headscale grants tightly, and don't advertise exit-node/routes you don't need.
