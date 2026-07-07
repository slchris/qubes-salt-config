{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Port-forward so a LAN machine can SSH to the jump qube. Qubes is double-NAT'd,
so DNAT is installed in BOTH hops:

  Mac ──► sys-net(physical IP):<ext_port> ──► sys-firewall ──► jump:22

Qubes 4.2/4.3 use **nftables**. Rules are added to the existing `ip qubes`
table using the official custom hook points (a `custom-dnat-*` chain, hook
prerouting, and the `custom-forward` chain) and persisted in each hop's
/rw/config/qubes-firewall-user-script, which Qubes runs on every firewall load.
So once written, the forwarding comes back automatically on every boot — no
manual step needed.

IMPORTANT — why this is driven entirely from dom0:
  qubesctl cannot run states in sys-net: Qubes denies sys-net the admin.* API by
  default (sys-net is the least-trusted qube), so `qubesctl --targets=sys-net`
  fails with "denied admin.vm.List ... sys-net -> dom0". Rather than loosen that
  (a real security downgrade), this whole formula runs in dom0 and pushes the
  firewall script into sys-net AND sys-firewall via qvm-run. Nothing runs as a
  Salt minion inside the service qubes.

Apply (dom0 only):
  sudo qubesctl state.apply mgmt.remote-debug.netfw

Requires cfg.remote_debug.network == "portforward" in config.jinja.
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set rd = cfg.remote_debug -%}
{%- set qube = rd.get('qube', 'mgmt-jump') -%}
{%- set ext_port = rd.get('ssh_port', 2333) -%}
{%- set network = rd.get('network', 'portforward') -%}
{%- set lan = rd.get('lan_subnet', '10.42.0.0/24') -%}
{%- set sysnet = rd.get('sysnet', 'sys-net') -%}
{%- set sysfw = rd.get('netvm', 'sys-firewall') -%}

{% if grains['nodename'] == 'dom0' and network == 'portforward' %}

{#- The firewall script for a hop. $DEST is resolved at run time inside the hop
    by qube name, so it survives IP changes. -#}
{#- Resolve the next-hop IPs in dom0 (where this runs). A qube cannot resolve a
    DOWNSTREAM qube's name (getent hosts sys-firewall fails inside sys-net), so
    we look them up here via qvm-prefs and bake the IP into each hop's script.
    Re-run `state.apply mgmt.remote-debug.netfw` if a qube is rebuilt and its IP
    changes. -#}
{%- set sysfw_ip = salt['cmd.run']('qvm-prefs ' ~ sysfw ~ ' ip', python_shell=True).strip() -%}
{%- set jump_ip = salt['cmd.run']('qvm-prefs ' ~ qube ~ ' ip', python_shell=True).strip() -%}

{%- macro fw_script(hop) -%}
#!/bin/sh
# remote-debug port-forward ({{ hop }}) — nftables. Managed by
# mgmt.remote-debug.netfw (pushed from dom0). Edit config.jinja, not this file.
EXT_PORT={{ ext_port }}
LAN="{{ lan }}"
{% if hop == 'sys-net' -%}
FWD_DPORT={{ ext_port }}
DEST="{{ sysfw_ip }}"
{% else -%}
FWD_DPORT=22
DEST="{{ jump_ip }}"
{% endif -%}
[ -n "$DEST" ] || { echo "remote-debug: next-hop IP empty (re-run netfw from dom0)" >&2; exit 0; }
# DNAT (prerouting) rewrites the destination to the next hop. We ALSO need SNAT
# (postrouting masquerade) so the next hop sees this gateway as the source —
# otherwise its reply goes back to the original client IP, which it cannot route,
# and the connection hangs. This is why plain DNAT alone timed out.
nft delete chain ip qubes custom-dnat-remotedebug 2>/dev/null || true
nft delete chain ip qubes custom-snat-remotedebug 2>/dev/null || true
nft add chain ip qubes custom-dnat-remotedebug '{ type nat hook prerouting priority -99 ; policy accept ; }'
nft add chain ip qubes custom-snat-remotedebug '{ type nat hook postrouting priority 99 ; policy accept ; }'
nft add rule ip qubes custom-snat-remotedebug ip daddr "$DEST" tcp dport "$FWD_DPORT" counter masquerade
{% if hop == 'sys-net' -%}
UPLINK="$(ip -4 route show default | awk '{print $5; exit}')"
[ -n "$UPLINK" ] || exit 0
nft add rule ip qubes custom-dnat-remotedebug iifname "$UPLINK" ip saddr "$LAN" tcp dport "$EXT_PORT" ct state new,established,related counter dnat to "${DEST}:${FWD_DPORT}"
nft add rule ip qubes custom-forward iifname "$UPLINK" ip saddr "$LAN" ip daddr "$DEST" tcp dport "$FWD_DPORT" ct state new,established,related counter accept
{% else -%}
# Flush any stale ARP/neigh entry for the jump. Each restart of the jump gives
# it a new vif, but a leftover PERMANENT neigh entry can pin the old vif/MAC, so
# forwarded packets go to a dead interface (sys-firewall->jump silently fails
# even though the jump has a working IP). Deleting it forces re-learning.
ip neigh flush to "$DEST" 2>/dev/null || true
for d in $(ip -o link show | sed -n 's/^[0-9]*: \(vif[0-9.]*\).*/\1/p'); do
  ip neigh del "$DEST" dev "$d" 2>/dev/null || true
done
# sys-firewall: the forwarded packet arrives with dst = sys-firewall's own IP
# (it was DNAT'd there by sys-net) on the external port. Match on that dst IP
# rather than iifgroup — the upstream interface group is not reliably 1, which
# is why the DNAT never matched and the packet stalled here (conntrack showed
# dst=<sysfw>:2333 UNREPLIED, un-DNAT'd).
SELF="$(ip -4 route get {{ jump_ip }} 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p')"
[ -n "$SELF" ] || SELF="{{ sysfw_ip }}"
nft add rule ip qubes custom-dnat-remotedebug ip daddr "$SELF" tcp dport "$EXT_PORT" ct state new,established,related counter dnat to "${DEST}:${FWD_DPORT}"
nft add rule ip qubes custom-forward ip daddr "$DEST" tcp dport "$FWD_DPORT" ct state new,established,related counter accept
{% endif -%}
{%- endmacro %}

{#- For each hop: stage the firewall script as a dom0 temp file (Salt-native
    file.managed, no jinja filters), then stream it into the hop's /rw/config
    via `qvm-run --pass-io`, chmod, and run it now. Using file.managed +
    --pass-io avoids both b64encode (absent in this Salt) and shell quoting. -#}
{% for hop in [sysnet, sysfw] %}
{%   set script = fw_script('sys-net' if hop == sysnet else 'sys-firewall') %}
{%   set staged = '/tmp/remote-debug-fw-' ~ hop ~ '.sh' %}

"remote-debug-netfw-stage-{{ hop }}":
  file.managed:
    - name: {{ staged }}
    - mode: '0644'
    - contents: |
        {{ script | indent(8) }}

"remote-debug-netfw-write-{{ hop }}":
  cmd.run:
    - name: |
        cat {{ staged }} | qvm-run --pass-io -u root -- {{ hop }} \
          'cat > /rw/config/qubes-firewall-user-script && chmod 0755 /rw/config/qubes-firewall-user-script'
    - onlyif: qvm-check --running {{ hop }}
    - require:
      - file: "remote-debug-netfw-stage-{{ hop }}"

"remote-debug-netfw-apply-{{ hop }}":
  cmd.run:
    - name: qvm-run --pass-io -u root -- {{ hop }} /rw/config/qubes-firewall-user-script
    - onlyif: qvm-check --running {{ hop }}
    - require:
      - cmd: "remote-debug-netfw-write-{{ hop }}"

{% endfor %}

{% endif %}
