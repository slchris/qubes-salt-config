# lisa2 Hysteria2 Exit on the .145 Qubes

How the `.145` Qubes machine reaches the internet through the **lisa2** host
over **Hysteria2 (QUIC)** instead of WireGuard, and why. `lisa2` is a second
host separate from the LAX Lisa box (see [lisa-exit.md](lisa-exit.md)); its
public address is a Wave Broadband Los Angeles **residential** IP
(`hosting=false proxy=false`, AS21775) — cleaner than a datacenter/transit
address, which is the point.

This is an operator record, not a formula. The server credential and the
client `config.json` are per-host/qube secrets and are **never** in this repo.

## Why Hysteria2 and not WireGuard here

On this box's cross-border path (~150 ms RTT to LA) a single WireGuard stream
collapses: measured ~0.05–1.2 MB/s. QUIC/Hysteria2, which carries its own
congestion control tuned for lossy high-RTT links, reached ~0.8–2.7 MB/s on the
same exit. WireGuard is kept as a slow-but-simple fallback (`sys-lisa2`); the
Hysteria2 gateway (`sys-hysteria-2`) is the fast path.

## Topology

```
Internet
   │  (lisa2 public IP, Wave Broadband LA residential, AS21775)
   ▼
lisa2 host  ── hysteria2 server, UDP 8443, self-signed cert (CN=lisa2.hy) ──┐
   ▲                                                                          │ Hysteria2/QUIC
   │                                                                          ▼
.145 Qubes:  sys-net → sys-firewall → sys-hysteria-2 (tpl-hysteria-net, sing-box)
                                    └── vc-project (tpl-agents)
```

- `sys-hysteria-2` is a `tpl-hysteria-net` ProxyVM. sing-box runs the
  Hysteria2 outbound over a gvisor tun (`10.139.1.0/30`, the Qubes virtual-DNS
  subnet), so downstream traffic is forwarded into the tun with no DNAT.
- Fail-closed is the `fail_closed()` step in `start.sh`, acting on Qubes' own
  `ip qubes-firewall forward` chain. If sing-box is down, downstream has no
  network.

## The stale fail-closed deadlock (fixed in the formula)

An earlier **hand-edited** build of `tpl-hysteria-net` shipped
`/etc/hysteria-net/base.nft` plus a `hysteria-net-fail-closed.service` that
loaded it at boot. That table's `output` chain is `policy drop` with **empty**
`bootstrap`/`output-dynamic` chains, so it drops the gateway's **own** egress
(the QUIC handshake to the server, DNS, the sing-box download) before the
tunnel can come up — a hard deadlock: a freshly created gateway has no network
at all and can never download its own binary.

Those files were never part of this repo (checked `git log -S`). They are now
declared absent by `salt/templates/hysteria-net/install.sls`
(`tpl-hysteria-net-remove-stale-*`), so rebuilding the template purges them.

## Deploy

The server side (below) is manual. The Qubes side is the salt formula:

```sh
# create the gateway qube (per-key entry in the .145 config.local.jinja
# hysteria_nets: {% set _ = cfg['hysteria_nets'].update({'hysteria-2': {}}) %})
sudo qubesctl top.enable templates.hysteria-net
sudo qubesctl state.apply templates.hysteria-net.create
sudo qubesctl --skip-dom0 --targets=tpl-hysteria-net state.apply templates.hysteria-net.install
sudo qubesctl --skip-dom0 --targets=sys-hysteria-2 state.apply templates.hysteria-net.configure
sudo qubesctl top.disable templates.hysteria-net
```

`configure` leaves `/rw/config/hysteria-net/config.json` as a CHANGEME
skeleton and downloads sing-box into `/rw/config/hysteria-net/bin/` (the
gateway has a netvm; the template does not). Fill the skeleton, then restart:

```sh
qvm-run -u root sys-hysteria-2 'sudo nano /rw/config/hysteria-net/config.json'
qvm-run -u root sys-hysteria-2 'systemctl restart hysteria-net-start.service'
```

`config.json` outbound (sing-box 1.9.7 — the field is `password`,
and this build does **not** accept `tls.pinSHA256`; use `insecure: true` for the
self-signed cert):

```json
{"type": "hysteria2", "tag": "proxy",
 "server": "<lisa2 IP>", "server_port": 8443, "password": "<password>",
 "tls": {"enabled": true, "server_name": "lisa2.hy", "insecure": true}}
```

Keep the rest of the skeleton (tun `10.139.1.0/30`, dns, route) untouched.

## Server side (manual, ~/etc/hysteria on lisa2)

Not salt-managed (the host is outside the Qubes salt scope, same as the
WireGuard servers on the Lisa hosts). Summary of what runs there:

| Item | Value |
|------|-------|
| Binary | `/usr/local/bin/hysteria` (v2.14.0, HyNetworks release) |
| Config | `/etc/hysteria/config.yaml` (mode 0600) |
| TLS | self-signed `/etc/hysteria/server.{crt,key}`, CN=`lisa2.hy`, 10y |
| Listen | UDP `8443` |
| Auth | `password` (type `password`), random 28-char |
| Unit | `hysteria-server.service` (systemd, enabled) |
| Firewall | UFW/iptables inbound allows `62408/tcp` (ssh), `51820/udp` (wg), `8443/udp` (hy2) |

`hysteria server -c /etc/hysteria/config.yaml`; the masquerade block proxies
non-Hysteria2 probes to a real site so the port looks unremarkable.

## Verification

```sh
# gateway up?
qvm-run -u root sys-hysteria-2 'ip -br link show tun0'
qvm-run -u root sys-hysteria-2 'systemctl restart hysteria-net-start.service'
qvm-run -u root sys-hysteria-2 'tail /run/hysteria-net/singbox.log'
# downstream exit + speed
qvm-run --pass-io vc-project 'curl -s https://ipinfo.io/json | grep -E "ip|org"'
qvm-run --pass-io vc-project 'curl -s -o /dev/null -w "%{speed_download}\n" \
  "https://speed.cloudflare.com/__down?bytes=20000000"'
```

## Notes and limitations

- **Rebuild wipes the binary.** `sys-hysteria-2` downloads sing-box from GitHub
  in `configure`. On this box clearnet GitHub is often unreachable until a
  tunnel exists; if the download fails, copy the binary from a working gateway
  (`sys-hysteria`) with a SHA check instead:
  `qvm-copy` or the `push-file` RemoteDebug action into
  `/rw/config/hysteria-net/bin/sing-box` (mode 0755).
- **sing-box is pinned to 1.9.7.** 1.10/1.11 segfault on start in this
  Debian/tmpfs AppVM.
- **Speed ceiling** is lisa2's residential *upload* bandwidth, not the tunnel;
  expect bursts to ~2–3 MB/s and slower sustained transfer.
- **Secrets** (`/etc/hysteria/config.yaml`, the client `config.json`,
  `server.key`) live only on the host / in the gateway's `/rw`; none belong in
  this repo.
