{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Install the transparent Hysteria2 gateway template (tpl-hysteria-net).

Runs sing-box with a userspace gvisor tun whose address is the Qubes virtual
DNS subnet (10.139.1.0/30), carrying a Hysteria2 (QUIC) outbound. That subnet
is the crux: downstream qubes already send 10.139.x/DNS to their netvm, so the
gateway needs no DNAT-to-local (which Qubes' forward policy would drop) — the
traffic is simply forwarded into tun0, exactly like the WireGuard gateway in
templates/project-net forwards into wg0.

Everything static lives here; the per-gateway server/auth secret is
/rw/config/hysteria-net/config.json, created as a skeleton by configure.sls.

Sing-box is pinned to 1.9.x: 1.10/1.11 builds segfault on start in this
Debian/tmpfs VM (Go runtime vs kernel), while 1.9.7 runs. The binary is
downloaded once into the template by a networked build qube? No — templates
have no netvm, so the binary is fetched by configure.sls INSIDE the gateway
(which has a netvm) and cached on /rw. install.sls only lays down the service
units and config skeletons.
#}

{% from 'config.jinja' import cfg with context %}
{%- set m = cfg.get('mirror', {}) -%}
{% if grains['nodename'] != 'dom0' %}

{% if m.get('enabled', False) and m.get('debian_baseurl', '') %}
include:
  - mgmt.mirror.debian
{% endif %}

"tpl-hysteria-net-update":
  pkg.uptodate:
    - refresh: True
{% if m.get('enabled', False) and m.get('debian_baseurl', '') %}
    - require:
      - cmd: mirror-debian-repoint
{% endif %}

"tpl-hysteria-net-packages":
  pkg.installed:
    - require:
      - pkg: tpl-hysteria-net-update
    - pkgs:
      # Makes a minimal template behave as a NetVM
      - qubes-core-agent-networking
      # nftables-native on R4.3 (Debian 13 minimal ships no iptables)
      - nftables
      - curl
      - ca-certificates
      - iproute2

"tpl-hysteria-net-start-script":
  file.managed:
    - name: /usr/bin/hysteria-net-start
    - source: salt://templates/hysteria-net/files/hysteria-net-start.sh
    - mode: '0755'
    - user: root
    - group: root
    - require:
      - pkg: tpl-hysteria-net-packages

# sing-box reads its config from /tmp (a copy made by the start script); the
# service just runs the /tmp copy the start script prepared.
"tpl-hysteria-net-singbox-unit":
  file.managed:
    - name: /etc/systemd/system/sing-box.service
    - mode: '0644'
    - user: root
    - group: root
    - contents: |
        # SPDX-License-Identifier: MIT — managed by templates.hysteria-net.install
        [Unit]
        Description=sing-box Hysteria2 gateway
        After=network.target nss-lookup.target
        ConditionPathExists=/tmp/hysteria-net-config.json

        [Service]
        Type=simple
        ExecStart=/tmp/sing-box run -c /tmp/hysteria-net-config.json
        Restart=always
        RestartSec=1
        LimitNPROC=10000
        LimitNOFILE=1000000
        AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
        NoNewPrivileges=true

        [Install]
        WantedBy=multi-user.target
    - require:
      - pkg: tpl-hysteria-net-packages

"tpl-hysteria-net-start-unit":
  file.managed:
    - name: /etc/systemd/system/hysteria-net-start.service
    - mode: '0644'
    - user: root
    - group: root
    - contents: |
        # SPDX-License-Identifier: MIT — managed by templates.hysteria-net.install
        [Unit]
        Description=hysteria-net gateway bring-up (tun + forwarding rules)
        After=local-fs.target qubes-network.service qubes-network-uplink@eth0.service
        Wants=qubes-network-uplink@eth0.service

        [Service]
        Type=oneshot
        RuntimeDirectory=hysteria-net
        RuntimeDirectoryMode=0750
        # The script lives on /rw, not /usr/bin: an AppVM's root does not
        # reliably refresh from its template's root on restart here, but /rw
        # is the AppVM's own persistent layer and always has the current copy.
        ExecStart=/rw/config/hysteria-net/start.sh --prepare
        RemainAfterExit=yes

        [Install]
        WantedBy=multi-user.target
    - require:
      - file: tpl-hysteria-net-start-script

# The sing-box unit is started *by* the start unit (ExecStart -> --prepare
# starts it); it must not be independently ordered before it.
"tpl-hysteria-net-enable":
  cmd.run:
    - name: systemctl enable hysteria-net-start.service
    - unless: systemctl is-enabled --quiet hysteria-net-start.service
    - runas: root
    - require:
      - file: tpl-hysteria-net-start-unit
      - file: tpl-hysteria-net-singbox-unit

{% endif %}
