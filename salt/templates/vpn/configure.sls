# SPDX-License-Identifier: MIT
# Copyright 2026 Chris Su
#
# Configure sys-vpn qube

# Create WireGuard config directory
"wireguard-dir":
  file.directory:
    - name: /rw/config/wireguard
    - user: root
    - group: root
    - mode: 700

# Create VPN startup script
"vpn-rc-local":
  file.managed:
    - name: /rw/config/rc.local
    - mode: 755
    - contents: |
        #!/bin/bash
        # VPN Gateway startup script

        # Enable IP forwarding
        echo 1 > /proc/sys/net/ipv4/ip_forward
        echo 1 > /proc/sys/net/ipv6/conf/all/forwarding

        # Start WireGuard if config exists
        if [ -f /rw/config/wireguard/wg0.conf ]; then
            wg-quick up /rw/config/wireguard/wg0.conf
        fi

        # Setup NAT for VPN traffic
        iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE
        iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE

# Create qubes-firewall-user-script for proper routing
"vpn-firewall-script":
  file.managed:
    - name: /rw/config/qubes-firewall-user-script
    - mode: 755
    - contents: |
        #!/bin/bash
        # Custom firewall rules for VPN gateway

        # Accept forwarded traffic
        iptables -I FORWARD -i eth0 -j ACCEPT
        iptables -I FORWARD -o eth0 -j ACCEPT

        # NAT for connected qubes
        iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE
        iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
