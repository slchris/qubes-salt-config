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
{%- macro fw_script(hop) -%}
#!/bin/sh
# remote-debug port-forward ({{ hop }}) — nftables. Managed by
# mgmt.remote-debug.netfw (pushed from dom0). Edit config.jinja, not this file.
EXT_PORT={{ ext_port }}
LAN="{{ lan }}"
{% if hop == 'sys-net' -%}
FWD_DPORT={{ ext_port }}
DEST="$(getent hosts {{ sysfw }} | awk '{print $1; exit}')"
{% else -%}
FWD_DPORT=22
DEST="$(getent hosts {{ qube }} | awk '{print $1; exit}')"
{% endif -%}
[ -n "$DEST" ] || { echo "remote-debug: cannot resolve next hop" >&2; exit 0; }
nft delete chain ip qubes custom-dnat-remotedebug 2>/dev/null || true
nft add chain ip qubes custom-dnat-remotedebug '{ type nat hook prerouting priority filter + 1 ; policy accept ; }'
{% if hop == 'sys-net' -%}
UPLINK="$(ip -4 route show default | awk '{print $5; exit}')"
[ -n "$UPLINK" ] || exit 0
nft add rule ip qubes custom-dnat-remotedebug iifname "$UPLINK" ip saddr "$LAN" tcp dport "$EXT_PORT" ct state new,established,related counter dnat to "${DEST}:${FWD_DPORT}"
nft add rule ip qubes custom-forward iifname "$UPLINK" ip saddr "$LAN" ip daddr "$DEST" tcp dport "$FWD_DPORT" ct state new,established,related counter accept
{% else -%}
nft add rule ip qubes custom-dnat-remotedebug iifgroup 1 tcp dport "$EXT_PORT" ct state new,established,related counter dnat to "${DEST}:${FWD_DPORT}"
nft add rule ip qubes custom-forward iifgroup 1 ip daddr "$DEST" tcp dport "$FWD_DPORT" ct state new,established,related counter accept
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
