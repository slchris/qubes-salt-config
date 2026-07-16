{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Install WireGuard gateway packages in tpl-project-net (Debian).

WireGuard-only on purpose: the kernel module is in-tree on Debian 13, every
provider that matters (Mullvad included) hands out standard wg-quick confs,
and a single tunnel type keeps the fail-closed firewall in configure.sls
simple enough to audit. If you need OpenVPN, use templates/vpn instead.
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

"tpl-project-net-update":
  pkg.uptodate:
    - refresh: True
{% if m.get('enabled', False) and m.get('debian_baseurl', '') %}
    - require:
      - cmd: mirror-debian-repoint
{% endif %}

"tpl-project-net-packages":
  pkg.installed:
    - require:
      - pkg: tpl-project-net-update
    - pkgs:
      # Makes a minimal template behave as a NetVM
      - qubes-core-agent-networking
      # WireGuard userspace tools (module is in-kernel on Debian 13)
      - wireguard-tools
      # wg-quick shells out to `resolvconf` to apply the conf's DNS= line to
      # the gateway's OWN resolution; without it wg-quick ABORTS on any conf
      # that carries DNS= — and Mullvad's generated configs always do.
      - openresolv
      # Kill-switch / NAT / downstream-DNS rules (R4.3 is nftables-native,
      # debian-13-minimal ships no iptables)
      - nftables
      - curl

# Enable IP forwarding so the qube can route downstream traffic into the
# tunnel once built from this template.
"tpl-project-net-ip-forward":
  file.managed:
    - name: /etc/sysctl.d/99-project-net-forward.conf
    - mode: '0644'
    - contents: |
        net.ipv4.ip_forward = 1
        net.ipv6.conf.all.forwarding = 1
    - require:
      - pkg: tpl-project-net-packages

# --- Fail-closed BASE policy, baked into the TEMPLATE ------------------------
# Loaded by a systemd oneshot very early on EVERY boot of every qube built
# from this template. This closes the window between `create`/`install` and
# `configure`: even a freshly created, never-configured sys-project-net drops
# downstream traffic instead of routing it clearnet. configure.sls's
# qubes-firewall-user-script block later re-loads this same file and appends
# the tunnel-specific dynamic rules (endpoint exception, DNS DNAT).
#
# The file is intentionally 100% static — no shell interpolation — so loading
# it can never fail on user input. The first two lines are the standard
# atomic-replace idiom (declare so delete cannot fail, delete, recreate — all
# one transaction).
#
# `inet` family covers IPv6 with the same chains. `output-dynamic` is an
# empty hook-less chain jumped BEFORE the eth0 drop: configure's script adds
# the WireGuard handshake exception there, so a failed add degrades to
# fully-closed, never to open.
"project-net-base-ruleset":
  file.managed:
    - name: /etc/project-net/base.nft
    - makedirs: True
    - mode: '0644'
    - user: root
    - group: root
    - contents: |
        # SPDX-License-Identifier: MIT — managed by templates.project-net.install
        table inet project-net
        delete table inet project-net
        table inet project-net {
          chain forward {
            type filter hook forward priority -10; policy accept;
            ct state established,related accept
            iifname "vif*" oifname "wg0" accept
            iifname "vif*" counter drop
          }
          chain output-dynamic {
          }
          chain output {
            type filter hook output priority -10; policy accept;
            oifname { "lo", "wg0" } accept
            ct state established,related accept
            jump output-dynamic
            oifname "eth0" counter drop
          }
          chain dnat-dns {
            type nat hook prerouting priority -110; policy accept;
          }
          chain postrouting {
            type nat hook postrouting priority srcnat; policy accept;
            oifname "wg0" masquerade
          }
        }
    - require:
      - pkg: tpl-project-net-packages

"project-net-fail-closed-unit":
  file.managed:
    - name: /etc/systemd/system/project-net-fail-closed.service
    - mode: '0644'
    - user: root
    - group: root
    - contents: |
        # SPDX-License-Identifier: MIT — managed by templates.project-net.install
        [Unit]
        Description=project-net fail-closed base firewall (before networking)
        DefaultDependencies=no
        After=local-fs.target
        Before=network-pre.target sysinit.target
        Wants=network-pre.target

        [Service]
        Type=oneshot
        ExecStart=/usr/sbin/nft -f /etc/project-net/base.nft
        RemainAfterExit=yes

        [Install]
        WantedBy=sysinit.target
    - require:
      - file: "project-net-base-ruleset"

"project-net-fail-closed-enable":
  cmd.run:
    - name: systemctl enable project-net-fail-closed.service
    - runas: root
    - unless: systemctl is-enabled --quiet project-net-fail-closed.service
    - require:
      - file: "project-net-fail-closed-unit"

{% endif %}
