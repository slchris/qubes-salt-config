{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Install the transparent HTTP-CONNECT proxy gateway in tpl-http-proxy-net.

Everything here is static: the fail-closed base table, redsocks and
dnscrypt-proxy configs, systemd units and the start script. The only
per-gateway secret is /rw/config/http-proxy-net/upstream.conf, which
configure.sls creates as an empty skeleton and the operator fills in.

The base table is loaded before networking by a oneshot, so a freshly
created, never-configured sys-http-proxy already drops downstream traffic
instead of forwarding it clearnet.
#}

{% from 'config.jinja' import cfg with context %}
{%- set m = cfg.get('mirror', {}) -%}
{% if grains['nodename'] != 'dom0' %}

{# Guard exactly like mgmt.mirror.debian declares its state: enabled AND a
   non-empty debian_baseurl — guarding on enabled alone would emit a require
   on `mirror-debian-repoint` that does not exist when the URL is blank. #}
{% if m.get('enabled', False) and m.get('debian_baseurl', '') %}
include:
  - mgmt.mirror.debian
{% endif %}

"tpl-http-proxy-net-update":
  pkg.uptodate:
    - refresh: True
{% if m.get('enabled', False) and m.get('debian_baseurl', '') %}
    - require:
      - cmd: mirror-debian-repoint
{% endif %}

"tpl-http-proxy-net-packages":
  pkg.installed:
    - require:
      - pkg: tpl-http-proxy-net-update
    - pkgs:
      # Makes a minimal template behave as a NetVM
      - qubes-core-agent-networking
      # nftables-native on R4.3; debian-13-minimal ships no iptables
      - nftables
      # Transparent TCP redirect for downstream qubes
      - redsocks
      # Local unauthenticated hop that adds Basic auth for the upstream
      - tinyproxy
      # Downstream DNS without leaking it to the Qubes resolvers
      - dnscrypt-proxy
      - curl
      - ca-certificates
      - iproute2

# --- Fail-closed BASE policy, baked into the TEMPLATE ------------------------
# 100% static, no shell interpolation, so loading it cannot fail on user
# input. The first two lines are the atomic-replace idiom.
#
#   prerouting  vif DNS -> local dnscrypt (:53); all other vif IPv4 TCP ->
#               local redsocks (:12345). priority -110 runs before Qubes'
#               own dnat-dns at dstnat -100, and the first nat chain to act
#               wins, so downstream DNS is never sent to the Qubes resolvers.
#   forward     policy drop, no rules. Redirected packets are local and never
#               reach this chain; anything that would be forwarded (IPv4 or
#               IPv6, including inbound forwards) is closed.
#   input       accept the redirected vif sockets; drop any other vif input;
#               drop eth0 attempts to use the unauthenticated local listeners.
#   output      policy drop. loopback (daemons talking to each other) and
#               replies to downstream vifs are allowed; `bootstrap` is
#               transiently filled by --prepare for the PROXY_HOST lookup;
#               `output-dynamic` carries the single upstream proxy endpoint.
#               There is deliberately no broad established accept and no
#               eth0 accept: a pre-existing clearnet flow must not survive.
#   bootstrap   empty; --prepare adds the Qubes-resolver accepts, resolves,
#               then flushes them and points /etc/resolv.conf at 127.0.0.1.
#   output-dynamic  empty; --rules rebuilds it from upstream.resolved.
"tpl-http-proxy-net-base-ruleset":
  file.managed:
    - name: /etc/http-proxy-net/base.nft
    - makedirs: True
    - mode: '0644'
    - user: root
    - group: root
    - contents: |
        # SPDX-License-Identifier: MIT — managed by templates.http-proxy-net.install
        table inet http-proxy-net
        delete table inet http-proxy-net
        table inet http-proxy-net {
          chain prerouting {
            type nat hook prerouting priority -110; policy accept;
            iifname "vif*" meta nfproto ipv4 udp dport 53 counter redirect to :53
            iifname "vif*" meta nfproto ipv4 tcp dport 53 counter redirect to :53
            iifname "vif*" meta nfproto ipv4 meta l4proto tcp counter redirect to :12345
          }
          chain forward {
            type filter hook forward priority -10; policy drop;
          }
          chain input {
            type filter hook input priority -10; policy accept;
            iifname "vif*" meta nfproto ipv4 udp dport 53 accept
            iifname "vif*" meta nfproto ipv4 tcp dport 53 accept
            iifname "vif*" meta nfproto ipv4 tcp dport 12345 accept
            iifname "vif*" counter drop
            iifname "eth0" meta nfproto ipv4 udp dport 53 counter drop
            iifname "eth0" meta nfproto ipv4 tcp dport 53 counter drop
            iifname "eth0" meta nfproto ipv4 tcp dport 12345 counter drop
          }
          chain bootstrap {
          }
          chain output-dynamic {
          }
          chain output {
            type filter hook output priority -10; policy drop;
            oifname "lo" accept
            oifname "vif*" accept
            jump bootstrap
            jump output-dynamic
          }
        }
    - require:
      - pkg: tpl-http-proxy-net-packages

# redsocks only talks to the local tinyproxy; the authenticated endpoint is
# in tinyproxy's generated `upstream` line. Bind 0.0.0.0, not loopback: nft
# `redirect` from a prerouting chain lands on the vif's primary address.
"tpl-http-proxy-net-redsocks-conf":
  file.managed:
    - name: /etc/http-proxy-net/redsocks.conf
    - makedirs: True
    - mode: '0644'
    - user: root
    - group: root
    - contents: |
        // SPDX-License-Identifier: MIT — managed by templates.http-proxy-net.install
        base {
          daemon = off;
          log = "syslog:daemon";
          user = redsocks;
          group = redsocks;
          redirector = iptables;
        }
        redsocks {
          local_ip = 0.0.0.0;
          local_port = 12345;
          ip = 127.0.0.1;
          port = 8888;
          type = http-connect;
          disclose_src = false;
          on_proxy_fail = close;
        }
    - require:
      - pkg: tpl-http-proxy-net-packages

# Static DoH stamps, and no resolver source list: Debian ships no
# resolver-list cache, and the default config would fetch one over the
# still-fail-closed network.
# http_proxy is required — the gateway's own DoH connection is not redirected,
# and a direct 1.0.0.1:443 packet would hit the output policy drop.
"tpl-http-proxy-net-dnscrypt-conf":
  file.managed:
    - name: /etc/dnscrypt-proxy/dnscrypt-proxy.toml
    - makedirs: True
    - mode: '0644'
    - user: root
    - group: root
    - contents: |
        # SPDX-License-Identifier: MIT — managed by templates.http-proxy-net.install
        listen_addresses = ['0.0.0.0:53']
        server_names = ['cloudflare', 'google']
        doh_servers = true
        dnscrypt_servers = false
        odoh_servers = false
        require_dnssec = true
        block_ipv6 = true
        force_tcp = true
        http_proxy = 'http://127.0.0.1:8888'
        ignore_system_dns = true
        netprobe_timeout = 0
        cache = true
        timeout = 10000
        max_clients = 250

        [static]
          [static.cloudflare]
          stamp = 'sdns://AgcAAAAAAAAABzEuMC4wLjEAEmRucy5jbG91ZGZsYXJlLmNvbQovZG5zLXF1ZXJ5'
          [static.google]
          stamp = 'sdns://AgUAAAAAAAAABzguOC44LjggalBisNF41VbxY7E7Gw8ZQ10CWIKRzHVYnf7m6xHI1cMHOC44LjguOAovZG5zLXF1ZXJ5'
    - require:
      - pkg: tpl-http-proxy-net-packages

"tpl-http-proxy-net-start-script":
  file.managed:
    - name: /usr/bin/http-proxy-net-start
    - source: salt://templates/http-proxy-net/files/http-proxy-net-start.sh
    # No `template:` option: file.managed copies `source` verbatim when
    # `template` is unset. Any renderer would read the script's shell
    # length-expansion syntax as the start of a Jinja comment.
    - mode: '0755'
    - user: root
    - group: root
    - require:
      - pkg: tpl-http-proxy-net-packages

"tpl-http-proxy-net-fail-closed-unit":
  file.managed:
    - name: /etc/systemd/system/http-proxy-net-fail-closed.service
    - mode: '0644'
    - user: root
    - group: root
    - contents: |
        # SPDX-License-Identifier: MIT — managed by templates.http-proxy-net.install
        [Unit]
        Description=http-proxy-net fail-closed base firewall (before networking)
        DefaultDependencies=no
        After=local-fs.target
        Before=network-pre.target sysinit.target
        Wants=network-pre.target

        [Service]
        Type=oneshot
        ExecStart=/usr/sbin/nft -f /etc/http-proxy-net/base.nft
        RemainAfterExit=yes

        [Install]
        WantedBy=sysinit.target
    - require:
      - file: tpl-http-proxy-net-base-ruleset

"tpl-http-proxy-net-start-unit":
  file.managed:
    - name: /etc/systemd/system/http-proxy-net-start.service
    - mode: '0644'
    - user: root
    - group: root
    - contents: |
        # SPDX-License-Identifier: MIT — managed by templates.http-proxy-net.install
        [Unit]
        Description=http-proxy-net config and daemon start
        After=local-fs.target qubes-network.service qubes-network-uplink@eth0.service
        Wants=qubes-network-uplink@eth0.service

        [Service]
        Type=oneshot
        RuntimeDirectory=http-proxy-net
        RuntimeDirectoryMode=0755
        ExecStart=/usr/bin/http-proxy-net-start --prepare
        RemainAfterExit=yes

        [Install]
        WantedBy=multi-user.target
    - require:
      - file: tpl-http-proxy-net-start-script

# The three daemon units are NOT enabled and carry no ordering dependency on
# http-proxy-net-start.service: --prepare restarts them from inside that
# service's own ExecStart, and a dependency back to it would deadlock the
# systemd transaction. ConditionPathExists is the safety net; --prepare
# writes `ready` only after a valid config.
"tpl-http-proxy-net-tinyproxy-unit":
  file.managed:
    - name: /etc/systemd/system/http-proxy-net-tinyproxy.service
    - mode: '0644'
    - user: root
    - group: root
    - contents: |
        # SPDX-License-Identifier: MIT — managed by templates.http-proxy-net.install
        [Unit]
        Description=tinyproxy for http-proxy-net (authenticated upstream CONNECT)
        ConditionPathExists=/run/http-proxy-net/ready
        After=local-fs.target

        [Service]
        Type=simple
        ExecStart=/usr/bin/tinyproxy -d -c /run/http-proxy-net/tinyproxy.conf
        Restart=always
        RestartSec=5

        [Install]
        WantedBy=multi-user.target
    - require:
      - pkg: tpl-http-proxy-net-packages

"tpl-http-proxy-net-redsocks-unit":
  file.managed:
    - name: /etc/systemd/system/http-proxy-net-redsocks.service
    - mode: '0644'
    - user: root
    - group: root
    - contents: |
        # SPDX-License-Identifier: MIT — managed by templates.http-proxy-net.install
        [Unit]
        Description=redsocks for http-proxy-net (downstream TCP to tinyproxy)
        ConditionPathExists=/run/http-proxy-net/ready
        After=local-fs.target http-proxy-net-tinyproxy.service

        [Service]
        Type=simple
        ExecStart=/usr/sbin/redsocks -c /etc/http-proxy-net/redsocks.conf
        Restart=always
        RestartSec=5

        [Install]
        WantedBy=multi-user.target
    - require:
      - file: tpl-http-proxy-net-redsocks-conf

"tpl-http-proxy-net-dnscrypt-unit":
  file.managed:
    - name: /etc/systemd/system/http-proxy-net-dnscrypt.service
    - mode: '0644'
    - user: root
    - group: root
    - contents: |
        # SPDX-License-Identifier: MIT — managed by templates.http-proxy-net.install
        [Unit]
        Description=dnscrypt-proxy for http-proxy-net (DoH through the upstream)
        ConditionPathExists=/run/http-proxy-net/ready
        After=local-fs.target http-proxy-net-tinyproxy.service http-proxy-net-redsocks.service

        [Service]
        Type=simple
        # Version-proof: do not depend on the username the Debian package
        # happens to create. A dynamic user plus the one capability the
        # daemon needs is enough to bind 0.0.0.0:53 and connect to tinyproxy.
        DynamicUser=yes
        AmbientCapabilities=CAP_NET_BIND_SERVICE
        CapabilityBoundingSet=CAP_NET_BIND_SERVICE
        NoNewPrivileges=yes
        ExecStart=/usr/sbin/dnscrypt-proxy -config /etc/dnscrypt-proxy/dnscrypt-proxy.toml
        Restart=always
        RestartSec=5

        [Install]
        WantedBy=multi-user.target
    - require:
      - file: tpl-http-proxy-net-dnscrypt-conf

# The packages ship their own units (dnscrypt even uses socket activation,
# which conflicts with listen_addresses). Mask them so only ours can run.
"tpl-http-proxy-net-mask-packaged":
  cmd.run:
    - name: |
        systemctl mask tinyproxy.service redsocks.service \
          dnscrypt-proxy.service dnscrypt-proxy.socket \
          dnscrypt-proxy-resolvconf.service >/dev/null 2>&1 || true
        systemctl daemon-reload
    - runas: root
    - require:
      - pkg: tpl-http-proxy-net-packages

"tpl-http-proxy-net-enable":
  cmd.run:
    - name: systemctl enable http-proxy-net-fail-closed.service http-proxy-net-start.service
    - unless: systemctl is-enabled --quiet http-proxy-net-fail-closed.service && systemctl is-enabled --quiet http-proxy-net-start.service
    - runas: root
    - require:
      - file: tpl-http-proxy-net-fail-closed-unit
      - file: tpl-http-proxy-net-start-unit
      - cmd: tpl-http-proxy-net-mask-packaged

{% endif %}
