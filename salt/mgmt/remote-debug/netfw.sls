{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Port-forward so a LAN machine can SSH to the jump qube (runs in sys-net AND
sys-firewall). Qubes is double-NAT'd, so DNAT is installed in BOTH hops:

  Mac ──► sys-net(physical IP):<ext_port> ──► sys-firewall ──► jump:22

Qubes 4.2/4.3 use **nftables** (not iptables). Rules are added to the existing
`ip qubes` table using the official custom hook points:
  - a `custom-dnat-<name>` chain (nat, hook prerouting, priority filter + 1)
  - the existing `custom-forward` chain (to accept the forwarded traffic)
This matches the Qubes firewall docs' port-forwarding example. Rules live in
/rw/config/qubes-firewall-user-script, which Qubes runs on every firewall load.

Apply targeting the two service qubes:
  sudo qubesctl --skip-dom0 --targets=sys-net,sys-firewall \
      state.apply mgmt.remote-debug.netfw

Requires cfg.remote_debug.network == "portforward" in config.jinja.

NOTE: Port forwarding through Qubes' double NAT is the most environment-specific
part of this formula (uplink interface name, LAN subnet). If it does not work,
docs/remote-debug.md has the manual steps and a mesh-VPN alternative.
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set rd = cfg.remote_debug -%}
{%- set qube = rd.get('qube', 'mgmt-jump') -%}
{%- set ext_port = rd.get('ssh_port', 2333) -%}
{%- set network = rd.get('network', 'portforward') -%}
{%- set lan = rd.get('lan_subnet', '192.168.0.0/16') -%}
{%- set host = grains['nodename'] -%}

{% if network == 'portforward' and host in ['sys-net', 'sys-firewall'] %}

{% if host == 'sys-net' %}
{%   set fwd_dport = ext_port %}
{%   set target_expr = 'sys-firewall' %}
{% else %}
{%   set fwd_dport = 22 %}
{%   set target_expr = qube %}
{% endif %}

"remote-debug-portfwd-{{ host }}":
  file.managed:
    - name: /rw/config/qubes-firewall-user-script
    - mode: '0755'
    - user: root
    - group: root
    - contents: |
        #!/bin/sh
        # remote-debug port-forward ({{ host }}) — nftables, Qubes 4.2/4.3.
        # Managed by mgmt.remote-debug.netfw. Edit config.jinja, not this file.
        EXT_PORT={{ ext_port }}
        FWD_DPORT={{ fwd_dport }}
        LAN="{{ lan }}"

        # Resolve the next hop's current IP by qube name (via Qubes DNS).
        DEST="$(getent hosts {{ target_expr }} | awk '{print $1; exit}')"
        [ -n "$DEST" ] || { echo "remote-debug: cannot resolve {{ target_expr }}" >&2; exit 0; }

        # Recreate our DNAT chain idempotently in the existing `ip qubes` table.
        nft delete chain ip qubes custom-dnat-remotedebug 2>/dev/null || true
        nft add chain ip qubes custom-dnat-remotedebug \
          '{ type nat hook prerouting priority filter + 1 ; policy accept ; }'

{% if host == 'sys-net' %}
        # sys-net: match on the physical uplink + LAN source, DNAT to sys-firewall.
        UPLINK="$(ip -4 route show default | awk '{print $5; exit}')"
        [ -n "$UPLINK" ] || exit 0
        nft add rule ip qubes custom-dnat-remotedebug \
          iifname "$UPLINK" ip saddr "$LAN" tcp dport "$EXT_PORT" \
          ct state new,established,related counter dnat to "${DEST}:${FWD_DPORT}"
        nft add rule ip qubes custom-forward \
          iifname "$UPLINK" ip saddr "$LAN" ip daddr "$DEST" tcp dport "$FWD_DPORT" \
          ct state new,established,related counter accept
{% else %}
        # sys-firewall: traffic arrives from the upstream interface group (1).
        nft add rule ip qubes custom-dnat-remotedebug \
          iifgroup 1 tcp dport "$EXT_PORT" \
          ct state new,established,related counter dnat to "${DEST}:${FWD_DPORT}"
        nft add rule ip qubes custom-forward \
          iifgroup 1 ip daddr "$DEST" tcp dport "$FWD_DPORT" \
          ct state new,established,related counter accept
{% endif %}

"remote-debug-portfwd-{{ host }}-apply":
  cmd.run:
    - name: /rw/config/qubes-firewall-user-script
    - runas: root
    - require:
      - file: "remote-debug-portfwd-{{ host }}"

{% endif %}
