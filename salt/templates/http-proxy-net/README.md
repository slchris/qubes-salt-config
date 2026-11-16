# http-proxy-net

Transparent HTTP-CONNECT proxy gateway (fail-closed) for Qubes OS.

## Table of Contents

*   [Description](#description)
*   [Installation](#installation)
*   [Supplying upstream.conf](#supplying-upstreamconf)
*   [Usage](#usage)
*   [Verification](#verification)
*   [Multiple gateways](#multiple-gateways)
*   [Notes and limitations](#notes-and-limitations)

## Description

Creates `sys-http-proxy`, a dedicated ProxyVM that sends every downstream
TCP connection through one upstream HTTP proxy using `CONNECT` (plain
`http://host:port`, Basic auth). Downstream DNS is answered locally by
dnscrypt-proxy over DoH, and that DoH connection also leaves through the same
upstream proxy. No downstream packet exits the gateway by any other path.

```
Internet <-> sys-net <-> sys-firewall <-> sys-http-proxy <-> project qube
                                            |
                                            +-- redsocks :12345 --> tinyproxy :8888
                                            +-- dnscrypt-proxy :53 --> tinyproxy :8888
                                                                         |
                                                                         +--CONNECT + Basic auth--> upstream
```

*   **Fail-closed.** The `inet http-proxy-net` base table is baked into the
    template and loaded before networking. `forward` and `output` both have
    `policy drop`; the only non-loopback egress is the upstream proxy
    `ip:port`. No config, a resolution failure or a dead proxy means the
    gateway stays closed — it never falls back to clearnet.
*   **Transparent.** Downstream qubes set no `HTTP_PROXY`; the gateway
    redirects every `vif*` IPv4 TCP connection to redsocks, which hands it to
    a local tinyproxy, which authenticates to the real upstream.
*   **Why the extra local tinyproxy hop.** redsocks 0.5's `http-connect`
    client does not send `Proxy-Authorization` when the upstream offers
    multiple auth schemes (darkk/redsocks#136). tinyproxy adds
    `Proxy-Authorization: Basic ...` on the CONNECT path, so redsocks talks
    to an unauthenticated local tinyproxy and tinyproxy authenticates
    upstream.
*   **DNS does not leak.** All downstream `:53` (TCP and UDP, to the Qubes
    virtual nameservers or anything else) is redirected to dnscrypt-proxy,
    which resolves through Cloudflare/Google DoH over the same upstream
    proxy. The Qubes resolvers are reachable only during the one-time
    bootstrap lookup of `PROXY_HOST`.

All three daemons are Debian 13 packages; nothing is downloaded by the
template itself.

## Installation

Deploy order matters: finish the template install and `configure` before
starting any qube that uses this gateway as netvm.

```sh
# 1. Template + gateway + per-gateway files (dom0)
sudo qubesctl top.enable templates.http-proxy-net
sudo qubesctl state.apply templates.http-proxy-net.create
sudo qubesctl --skip-dom0 --targets=tpl-http-proxy-net \
  state.apply templates.http-proxy-net.install

# 2. Start the gateway so the fail-closed base table is loaded
qvm-start sys-http-proxy

# 3. Create the skeleton and install the firewall block (gateway stays closed)
sudo qubesctl --skip-dom0 --targets=sys-http-proxy \
  state.apply templates.http-proxy-net.configure

sudo qubesctl top.disable templates.http-proxy-net
```

`configure` creates `/rw/config/http-proxy-net/upstream.conf` mode `0600`
root and never overwrites it on re-apply. It leaves the gateway **fully
closed**: the skeleton is empty, so the start service logs
`gateway fully closed` and exits 0.

## Supplying upstream.conf

The proxy hostname and credentials are a secret and are deliberately not
salt-managed. Inside `sys-http-proxy` (debian-minimal has no editor of its
own, so either install one or pipe the file in from dom0):

```sh
sudoedit /rw/config/http-proxy-net/upstream.conf
```

```sh
# alternative, from dom0: overwrite in place, keeping root:0600
qvm-run --pass-io -u root sys-http-proxy \
  'cat > /rw/config/http-proxy-net/upstream.conf' < upstream.conf
```

Uncomment and fill:

```sh
PROXY_HOST=proxy.example.net
PROXY_PORT=8080
PROXY_USER=youruser
PROXY_PASS=yourpassword
#PROXY_IP=
#CONNECT_PORTS=80,443
```

*   `PROXY_HOST` is a hostname or an IPv4 literal.
*   `PROXY_USER` must not contain `:`; `PROXY_PASS` must not contain `@`,
    whitespace, quotes, `#` or a backslash (tinyproxy's credential syntax).
*   `PROXY_IP` pins the endpoint and skips the bootstrap DNS lookup.
*   `CONNECT_PORTS` must include `443` (dnscrypt's DoH goes through
    tinyproxy) and defaults to `80,443`. Add `22` for git-over-SSH only if
    the upstream allows it.

Then validate and apply:

```sh
sudo /usr/bin/http-proxy-net-start --check
sudo systemctl restart http-proxy-net-start.service
```

Editing the file alone changes nothing. The start service is the only thing
that re-resolves the host, rebuilds the dynamic nft rule, regenerates
tinyproxy's config and restarts the daemons.

`/rw` persists across reboots; do not use `/etc/http-proxy-net` for the
secret — that path is reset with the root volume on every AppVM boot.

## Usage

Create the project AppVM from `tpl-agents`, point it at this gateway, and
start it. First add the qube and a `sys-http-proxy` exit entry to
`salt/config.local.jinja` (not the public repo) and redeploy, so `agents.exit`
can bind the proxy region's timezone/locale:

```jinja
{% set _ = cfg['agents']['qubes'].append('myproxy-project') %}
{% set _ = cfg['agents']['exits'].update({
  'sys-http-proxy': {'timezone': 'Asia/Shanghai', 'locale': 'en_US.UTF-8'},
}) %}
```

Then, in dom0:

```sh
qvm-create --template tpl-agents --label blue myproxy-project
qvm-prefs myproxy-project netvm sys-http-proxy
qvm-prefs myproxy-project memory 800
qvm-prefs myproxy-project maxmem 8000
qvm-prefs myproxy-project audiovm dom0
qvm-start myproxy-project

sudo qubesctl state.apply agents.exit
sudo qubesctl --skip-dom0 --targets=myproxy-project state.apply agents.configure
```

`agents.exit` fails if a listed qube's netvm has no `cfg.agents.exits` entry.
`agents.configure` then runs the exit script so a running qube picks the
binding up without a restart. If the qube is deliberately not in
`cfg.agents.qubes`, skip the overlay edit and `agents.exit`; `agents.configure`
still works and leaves the image's fallback timezone/locale in place.

Do **not** set `HTTP_PROXY`/`HTTPS_PROXY` inside the qube.

## Verification

```sh
# Inside sys-http-proxy:
sudo nft list table inet http-proxy-net          # forward and output: policy drop
sudo nft list chain inet http-proxy-net output-dynamic   # one upstream ip:port
sudo nft list chain ip qubes custom-input | grep http-proxy-net
systemctl status 'http-proxy-net-*'
sudo /usr/bin/http-proxy-net-start --check       # exit 0
sudo curl --proxy http://127.0.0.1:8888 -sS https://api.ipify.org
getent ahosts example.com                         # dnscrypt -> tinyproxy -> upstream

# Inside the project qube:
curl -sS https://api.ipify.org                    # the proxy exits here
getent ahosts example.com                         # DNS works
```

The gateway's own plain `curl`/`apt` does **not** work: its only non-loopback
egress is the upstream proxy endpoint. Use `curl --proxy http://127.0.0.1:8888`
there.

Kill-switch test: in `sys-http-proxy`, `sudo systemctl stop
http-proxy-net-tinyproxy`, then the downstream `curl` must fail — never fall
back to the real IP. Restart the unit afterwards.

## Multiple gateways

Every gateway is one key in `cfg.http_proxy_nets` (`salt/config.jinja`). The
key becomes `sys-<key>`; `"http-proxy"` preserves `sys-http-proxy`.

```jinja
"http_proxy_nets": {
  "http-proxy": {},
  "http-proxy-2": {"netvm": "sys-firewall", "memory": 400},
},
```

All gateways share `tpl-http-proxy-net` and the same fail-closed states.
Each one needs its own `/rw/config/http-proxy-net/upstream.conf`; the
upstream proxy and its credentials are never stored in Salt or git.
Per-key overrides are optional: `template`, `label`, `netvm`, `memory`,
`maxmem`. `init.top` and `configure.top` loop over the map, so adding a key
is enough for the highstate.

## Notes and limitations

*   HTTP CONNECT carries TCP only. Downstream UDP other than DNS is dropped
    (QUIC/WebRTC fall back to TCP or fail), and there is no IPv6 path.
*   Transparent proxying loses the destination hostname: redsocks sends
    `CONNECT <ip>:<port>`, so the upstream proxy sees IPs. An upstream that
    filters by hostname will reject it; IP-based ACLs are required.
*   The connection to the upstream proxy is plain HTTP with Basic
    credentials. The password is not protected on the path between this
    gateway and the proxy.
*   The proxy provider sees the real source IP (that is how it is reached)
    and the destination IPs. TLS stays end-to-end; content is not exposed.
*   The redirect happens in the gateway's prerouting chain, before Qubes'
    per-qube firewall rules. A downstream qube's Qubes firewall therefore
    cannot filter proxied destinations; the upstream proxy is the only
    policy point. Do not rely on per-qube rules to restrict a qube behind
    this gateway.
*   Inbound forwards to a downstream qube (for example magpie) are not
    supported: the `forward` chain is `policy drop`.
*   Qubes updates do not use this path: `qubes.UpdatesProxy` is qrexec to the
    UpdateVM (normally `sys-firewall`), not TCP through the qube's netvm, so
    `apt` in a downstream qube is unaffected by this gateway and still leaves
    through the UpdateVM's own uplink.
*   `PROXY_HOST` is resolved once per start and cached in
    `/run/http-proxy-net/upstream.resolved` (tmpfs). An IP change mid-run
    needs `systemctl restart http-proxy-net-start.service`. Pin `PROXY_IP`
    if the hostname's DNS is unreliable.
*   The bootstrap lookup of `PROXY_HOST` goes to the Qubes resolver
    directly; `PROXY_IP` avoids it entirely. After `--prepare`, the
    gateway's own `/etc/resolv.conf` points at `127.0.0.1`, so every other
    lookup the gateway does goes through dnscrypt.
*   DoH server IPs are pinned in static stamps in
    `templates.http-proxy-net.install` (no resolver-list fetch at boot, which
    would need the network before DNS works). If Cloudflare or Google retire
    those IPs, update the two stamps.

## Qubes Created

| Qube | Type | Description |
|------|------|-------------|
| tpl-http-proxy-net | Template | Debian minimal + redsocks/tinyproxy/dnscrypt-proxy |
| sys-http-proxy | AppVM | Transparent HTTP-CONNECT gateway (ProxyVM) |

## License

SPDX-License-Identifier: MIT

Copyright 2026 Chris Su
