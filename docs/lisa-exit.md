# Lisa Exit on the .145 Qubes

How the `.145` Qubes machine reaches the internet through the **Lisa** host: a
single-hop WireGuard gateway (`sys-lisa`) and one project AppVM
(`slchris-dev`), with no Mullvad hop in between. Egress is Lisa's own
NTT America (AS2914) address in Los Angeles.

This is an operator record, not a formula. The wiring lives in `.145`'s
gitignored `config.local.jinja` (deployed only from the temporary deploy
tarball); the gateway's `wg0.conf` is a per-qube secret and is **never** in this
repo.

## Topology

```
Internet
   │  (Lisa public IP, AS2914 NTT, Los Angeles)
   ▼
Lisa host  ── wg0 51820/udp, 10.66.66.1/24 ──┐
   ▲                                          │ WireGuard tunnel
   │  peer 10.66.66.3/32                      │
   │                                          ▼
.145 Qubes:  sys-net → sys-firewall → sys-lisa (tpl-project-net, fail-closed)
                                          └── slchris-dev (tpl-agents)
```

- `sys-lisa` is a `tpl-project-net` ProxyVM: if the tunnel is down it drops
  downstream traffic instead of falling back to clearnet.
- `slchris-dev` is an ordinary agent AppVM built from `tpl-agents`;
  its `netvm` is `sys-lisa`.

## What is on the Lisa host

| Item | Value |
|------|-------|
| WireGuard listen | UDP `51820` |
| WireGuard subnet | `10.66.66.1/24` (server `10.66.66.1`) |
| Peer: phone | `10.66.66.2/32` |
| Peer: .145 gateway (`sys-lisa`) | `10.66.66.3/32` |
| Snell | TCP `8388` (Surge/Stash) |
| SSH | TCP `49727`, YubiKey only (password login disabled) |
| Firewall | UFW, inbound allows only `49727/tcp`, `8388/tcp`, `51820/udp` |
| NAT | forwards `10.66.66.0/24` out the uplink interface (`ens17`) |

The gateway's public key is pinned as a peer on Lisa; its private key lives only
in `/rw/config/wireguard/wg0.conf` inside `sys-lisa`.

## .145 salt overlay (config.local.jinja)

The overlay drops the default `project-net` key (so nothing builds
`sys-project-net`), adds the `lisa` gateway, points `agent-build` at it, and
declares the `slchris-dev` project:

```jinja
{% set _ = cfg['project_nets'].pop('project-net', None) %}
{% set _ = cfg['project_nets'].update({'lisa': {}}) %}

{% set _ = cfg['agents']['build'].update({'netvm': 'sys-lisa'}) %}
{% set _ = cfg['agents']['exits'].update({
  'sys-lisa': {'timezone': 'America/Los_Angeles', 'locale': 'en_US.UTF-8'},
}) %}

{% set _ = cfg['agents'].update({'qubes': ['slchris-dev']}) %}
{% set _ = cfg['qubes'].update({
  'slchris-dev': {'git': {'name': 'Chris Su', 'email': 'chris@plz.ac'}},
}) %}
```

The old lv-relay gateway `sys-ardis`, its project `ardiszheng`, and the unused
`sys-aws-net` are retired on this machine in favour of the Lisa exit.

## Deploy (driven over qubes.RemoteDebug)

`.145` is managed from the Mac through the `mgmt-jump` qube's
`qubes.RemoteDebug` allow-list (see [remote-debug.md](remote-debug.md)). There
is no editable salt checkout on the machine: deploy by packaging locally,
copying the tarball to the jump qube, and calling the service's `deploy`
action.

```sh
# 1. Put the tarball (which MUST include salt/config.local.jinja — package.sh
#    excludes it, so build it by hand) on the jump qube:
scp -P 2333 qubes-salt-config-deploy.tar.gz user@10.31.0.145:/tmp/qsc-deploy.tar.gz

# 2. Deploy: pulls it into dom0, extracts, runs scripts/setup.sh.
#    The trailing newline matters: the service does `read -r cmdline`.
ssh -p 2333 user@10.31.0.145 \
  "printf '%s\n' 'deploy mgmt-jump' | qrexec-client-vm dom0 qubes.RemoteDebug"

# 3. Create/refresh the gateway (dom0), then install + configure it.
ssh -p 2333 user@10.31.0.145 "printf '%s\n' 'qubesctl state.apply templates.project-net.create'        | qrexec-client-vm dom0 qubes.RemoteDebug"
ssh -p 2333 user@10.31.0.145 "printf '%s\n' 'qubesctl --skip-dom0 --targets=tpl-project-net state.apply templates.project-net.install' | qrexec-client-vm dom0 qubes.RemoteDebug"
ssh -p 2333 user@10.31.0.145 "printf '%s\n' 'qubesctl --skip-dom0 --targets=sys-lisa state.apply templates.project-net.configure'      | qrexec-client-vm dom0 qubes.RemoteDebug"
```

## Supply the WireGuard credential

The tunnel secret is per-qube and not salt-managed. Write a standard wg-quick
conf into `/rw/config/wireguard/wg0.conf` (mode 0600) inside `sys-lisa`:

```ini
[Interface]
Address = 10.66.66.3/32
PrivateKey = <sys-lisa private key>
DNS = 1.1.1.1
MTU = 1380

[Peer]
PublicKey = <Lisa host public key>
Endpoint = <Lisa public IP>:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
```

Then `qvm-shutdown --wait sys-lisa && qvm-start sys-lisa`. Verify inside the
gateway:

```sh
sudo wg show                     # latest handshake within ~25s
curl -s https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(ip|loc|colo)='
# ip=<Lisa IP>  loc=US  colo=LAX
```

## Create the project AppVM

There is no create state for a plain agent project qube — create it by hand,
as in [salt/agents/README.md](../salt/agents/README.md):

```sh
qvm-create --template tpl-agents --label blue slchris-dev
qvm-prefs slchris-dev netvm sys-lisa
qvm-prefs slchris-dev memory 800
qvm-prefs slchris-dev maxmem 8000
qvm-prefs slchris-dev audiovm dom0
qubesctl state.apply agents.exit        # timezone/locale from sys-lisa's exit
qvm-start slchris-dev
qubesctl --skip-dom0 --targets=slchris-dev state.apply agents.configure
```

## Verification

From inside `slchris-dev`:

```sh
curl -s https://ipinfo.io/json | grep -E '"(ip|city|org)"'
# ip: <Lisa IP>  city: Los Angeles  org: AS2914 NTT America
```

IP-purity at the time of setup (Lisa's clean NTT address, not a flagged
datacenter/proxy):

- Scamalytics Fraud Score: 8
- ip-api: `proxy=false hosting=false mobile=false`
- stopforumspam: no records

## Notes and limitations

- **Fail-closed.** If the Lisa tunnel is down, `slchris-dev` and
  `agent-build` lose the network rather than leaking via `sys-firewall`.
- **A hostname Endpoint does not work** under the kill-switch (it cannot
  resolve before the tunnel exists). Use the Lisa IP literal.
- **Secret locations.** The Lisa server key and peer public keys live on the
  Lisa host (`/etc/wireguard/wg0.conf`, plus the generated `syslisa_private.key`
  / `syslisa_public.key`); the gateway private key lives only in `sys-lisa`.
  None of them belong in this repo.
- The `qvm-remove` allow-list in `mgmt/remote-debug/files/qubes.RemoteDebug`
  does **not** cover project qube names. Retiring a project qube such as
  `ardiszheng` needs either a temporary exact-name entry (as was done, then
  reverted) or a manual `qvm-remove` in dom0.
