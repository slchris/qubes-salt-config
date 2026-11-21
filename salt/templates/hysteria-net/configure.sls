{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Configure the sys-hysteria gateway (runs IN the qube, not dom0).

Creates /rw/config/hysteria-net/config.json as a skeleton, downloads the
pinned sing-box binary into /rw/config/hysteria-net/bin (the template has no
netvm; the gateway does), and brings the gateway up. The Hysteria2 server
address / password / TLS are a secret and are never salt-managed: the operator
fills the skeleton and restarts hysteria-net-start.service.

Deploy (from dom0):
  sudo qubesctl --skip-dom0 --targets=sys-hysteria state.apply templates.hysteria-net.configure
#}

{% from 'config.jinja' import cfg with context %}
{%- set hy = cfg.get('hysteria_net', {}) -%}
{%- set sb_version = hy.get('singbox_version', '1.9.7') -%}
{% if grains['nodename'] != 'dom0' %}

"hysteria-net-config-dir":
  file.directory:
    - name: /rw/config/hysteria-net
    - user: root
    - group: root
    - mode: '0750'

"hysteria-net-bin-dir":
  file.directory:
    - name: /rw/config/hysteria-net/bin
    - user: root
    - group: root
    - mode: '0750'

# Download the pinned sing-box build once into /rw. It is fetched here, not in
# the template, because a template has no netvm. If the gateway's own egress is
# already fail-closed, the start script's bootstrap-free first run may still
# reach the mirror through sys-firewall before any downstream qube is attached.
"hysteria-net-singbox-bin":
  cmd.run:
    - name: |
        set -eu
        B=/rw/config/hysteria-net/bin/sing-box
        [ -x "$B" ] && "$B" version 2>/dev/null | grep -q '{{ sb_version }}' && exit 0
        tmp=$(mktemp -d)
        curl -fsSL --retry 3 -o "$tmp/sb.tgz" \
          "https://github.com/SagerNet/sing-box/releases/download/v{{ sb_version }}/sing-box-{{ sb_version }}-linux-amd64.tar.gz"
        tar -xzf "$tmp/sb.tgz" -C "$tmp"
        install -m 0755 "$tmp/sing-box-{{ sb_version }}-linux-amd64/sing-box" "$B"
        rm -rf "$tmp"
        "$B" version | grep -q '{{ sb_version }}'
    - runas: root
    - require:
      - file: hysteria-net-bin-dir

# replace: False — an existing config.json is never overwritten by a re-apply.
# The server secret lives only in this file, on /rw.
"hysteria-net-config":
  file.managed:
    - name: /rw/config/hysteria-net/config.json
    - user: root
    - group: root
    - mode: '0600'
    - replace: False
    - contents: |
        # SPDX-License-Identifier: MIT — managed by templates.hysteria-net.configure
        #
        # Fill in the hysteria2 outbound (server / password / sni), then:
        #   sudo systemctl restart hysteria-net-start.service
        #
        # server    IPv4 literal (or DNS name); the tunnel resolver lives on the
        #           server side, so a hostname is resolved by sing-box itself
        #           over the tunnel bootstrap (dial before tun routing).
        # password  the Hysteria2 shared password.
        # tls.server_name  must match the server certificate CN/SAN.
        # tls.insecure     true only for a self-signed certificate.
        #
        # Keep the tun inet4_address 10.139.1.0/30 (Qubes virtual DNS subnet)
        # and the dns/route blocks as-is — downstream qubes depend on them.
        #
        # This file is on /rw only. Never commit it.
        {
          "log": {"level": "info"},
          "dns": {
            "servers": [
              {"tag": "remote", "address": "tls://1.1.1.1", "detour": "proxy"},
              {"tag": "dnsout", "address": "local", "detour": "direct"}
            ],
            "final": "remote",
            "strategy": "prefer_ipv4"
          },
          "inbounds": [
            {"type": "tun", "tag": "tun-in", "stack": "gvisor",
             "inet4_address": "10.139.1.0/30",
             "auto_route": true, "strict_route": true, "sniff": true}
          ],
          "outbounds": [
            {"type": "hysteria2", "tag": "proxy",
             "server": "CHANGEME", "server_port": 8443, "password": "CHANGEME",
             "tls": {"enabled": true, "server_name": "CHANGEME", "insecure": true}
            },
            {"type": "direct", "tag": "direct"},
            {"type": "dns", "tag": "dnsout"}
          ],
          "route": {
            "auto_detect_interface": true,
            "rules": [{"protocol": "dns", "outbound": "dnsout"}],
            "final": "proxy"
          }
        }
    - require:
      - file: hysteria-net-config-dir

# The start script is installed to /rw, not /usr/bin: an AppVM root does not
# reliably refresh from the template root on restart in this deployment, but
# /rw is the AppVM's own persistent layer and always has the current copy. The
# systemd unit execs this /rw path.
"hysteria-net-start-script-rw":
  file.managed:
    - name: /rw/config/hysteria-net/start.sh
    - source: salt://templates/hysteria-net/files/hysteria-net-start.sh
    - mode: '0755'
    - user: root
    - group: root
    - require:
      - file: hysteria-net-config-dir

# The gateway is driven from /rw/config/rc.local on every boot. A systemd unit
# from the template is not trusted here: this AppVM's root can be a stale
# template clone that never refreshes, but /rw is the AppVM's own persistent
# layer and always holds the current script.
"hysteria-net-rc-local":
  file.blockreplace:
    - name: /rw/config/rc.local
    - marker_start: "# >>> hysteria-net >>>"
    - marker_end: "# <<< hysteria-net <<<"
    - append_if_not_found: True
    - content: |
        # Managed by templates.hysteria-net.configure — do not edit between markers.
        if [ -x /rw/config/hysteria-net/start.sh ]; then
          /rw/config/hysteria-net/start.sh --prepare >> /rw/config/hysteria-net/boot.log 2>&1
        fi
    - require:
      - file: hysteria-net-start-script-rw

"hysteria-net-rc-shebang":
  cmd.run:
    - name: |
        f=/rw/config/rc.local
        head -n1 "$f" | grep -q '^#!' || sed -i '1i #!/bin/sh' "$f"
        chmod 0755 "$f"
    - runas: root
    - require:
      - file: hysteria-net-rc-local

# --check fails the state on an invalid non-empty conf (loud), but a skeleton
# with CHANGEME is fine: the gateway stays closed. Then bring it up now.
"hysteria-net-apply-now":
  cmd.run:
    - name: |
        set -eu
        /rw/config/hysteria-net/start.sh --check
        /rw/config/hysteria-net/start.sh --prepare
        nft list chain ip qubes-firewall forward >/dev/null
        ip rule show | grep -q '10.137.0.0/16 lookup main'
    - runas: root
    - require:
      - file: hysteria-net-config
      - file: hysteria-net-start-script-rw
      - cmd: hysteria-net-singbox-bin

{% endif %}
