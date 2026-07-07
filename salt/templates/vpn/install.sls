# SPDX-License-Identifier: MIT
# Copyright 2026 Chris Su
#
# Install VPN packages in tpl-vpn (Fedora)

{% if grains['nodename'] != 'dom0' %}

"vpn-update":
  pkg.uptodate:
    - refresh: True

"vpn-packages":
  pkg.installed:
    - require:
      - pkg: vpn-update
    - install_recommends: False
    - skip_suggestions: True
    - setopt: "install_weak_deps=False"
    - pkgs:
      # Qubes networking
      - qubes-core-agent-networking
      # WireGuard
      - wireguard-tools
      # OpenVPN
      - openvpn
      - NetworkManager-openvpn
      - NetworkManager-openvpn-gnome
      # Network utilities
      - iptables-services
      - nftables
      - curl
      - bind-utils

# Enable IP forwarding in template
"ip-forward-conf":
  file.managed:
    - name: /etc/sysctl.d/99-vpn-forward.conf
    - contents: |
        net.ipv4.ip_forward = 1
        net.ipv6.conf.all.forwarding = 1

{% endif %}
