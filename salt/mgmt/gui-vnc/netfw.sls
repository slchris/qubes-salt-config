{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Expose the browser front end on the LAN (runs IN dom0).

Qubes is double-NAT'd, so a port that should be reachable from the LAN needs a
DNAT in BOTH hops:

  LAN client --> sys-net:<ext_port> --> sys-firewall --> <web qube>:<web_port>

This is the same mechanism, and the same boot-order and DispVM caveats, as
mgmt.remote-debug.netfw; read that file's header for the full reasoning (nft
rules must not depend on routing being up, sys-firewall is a DispVM in R4.3 so
the rules have to be written into its DVM template, and so on). Only the
destination qube and port differ.

This is deliberately LAN-only. The DNAT is source-filtered to
cfg.remote_debug.lan_subnet, and it assumes the web qube is exactly two hops
behind sys-net. It is NOT a VPN path: Tailscale subnet routes SNAT their
traffic, so a tailnet client's packets arriving at sys-net do not match the LAN
source filter. If you ever want off-LAN access, that is a different design
(the module README explains why), not a matter of widening lan_subnet.

Requires cfg.gui_vnc.web.network == "portforward". Any other value is a no-op.

Apply (dom0 only):
  sudo qubesctl state.apply mgmt.gui-vnc.netfw
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set gv = cfg.get('gui_vnc', {}) -%}
{%- set web = gv.get('web', {}) -%}
{%- set qube = web.get('qube', 'sys-vncweb') -%}
{%- set listen = web.get('listen', '0.0.0.0:6080') -%}
{%- set web_port = listen.split(':')[-1] -%}
{%- set ext_port = web.get('ext_port', web_port) -%}
{%- set network = web.get('network', 'portforward') -%}
{%- set sysnet = 'sys-net' -%}
{%- set sysfw = web.get('netvm', 'sys-firewall') -%}

{% if grains['nodename'] == 'dom0' and gv.get('enabled', False) and web.get('enabled', False) and network == 'portforward' %}

{%- set sysfw_ip = salt['cmd.run']('qvm-prefs ' ~ sysfw ~ ' ip', python_shell=True).strip() -%}
{%- set web_ip = salt['cmd.run']('qvm-prefs ' ~ qube ~ ' ip', python_shell=True).strip() -%}

{#- Client subnets allowed to reach the forwarded port. Defaults to the same
    list mgmt.remote-debug uses. -#}
{%- set lan_raw = cfg.get('remote_debug', {}).get('lan_subnet', '10.31.0.0/24') -%}
{%- set lans = [lan_raw] if lan_raw is string else lan_raw -%}

{%- macro fw_script(hop, qname) -%}
# >>> gui-vnc (managed by mgmt.gui-vnc.netfw — do not edit) >>>
EXT_PORT={{ ext_port }}
WEB_PORT={{ web_port }}
{% if hop == 'sys-net' -%}
FWD_DPORT={{ ext_port }}
DEST="{{ sysfw_ip }}"
{% else -%}
FWD_DPORT={{ web_port }}
DEST="{{ web_ip }}"
{% endif -%}
# NEVER `exit` from this block: this file is shared with other formulas whose
# blocks may follow ours, and the firewall script runs before routing exists.
# Rules are matched on ip saddr/daddr so they install correctly at boot; the
# interface name is only an optional tightening.
GV_SELF="$(qubesdb-read /name 2>/dev/null)"
if [ "$GV_SELF" != "{{ qname }}" ]; then
  : # inherited by a sibling disposable from the shared DVM template
elif [ -z "$DEST" ]; then
  echo "gui-vnc: next-hop IP empty (re-run netfw from dom0)" >&2
else
  nft delete chain ip qubes custom-dnat-guivnc 2>/dev/null || true
  nft delete chain ip qubes custom-snat-guivnc 2>/dev/null || true
  nft add chain ip qubes custom-dnat-guivnc '{ type nat hook prerouting priority -99 ; policy accept ; }'
  nft add chain ip qubes custom-snat-guivnc '{ type nat hook postrouting priority 99 ; policy accept ; }'
  nft add rule ip qubes custom-snat-guivnc ip daddr "$DEST" tcp dport "$FWD_DPORT" counter masquerade
  nft -a list chain ip qubes custom-forward 2>/dev/null \
    | grep -F "ip daddr $DEST" | grep -F "tcp dport $FWD_DPORT" \
    | grep -o 'handle [0-9]*' | awk '{print $2}' \
    | while read -r h; do nft delete rule ip qubes custom-forward handle "$h" 2>/dev/null || true; done
{%- if hop == 'sys-net' %}
  for LAN in {{ lans | join(' ') }}; do
    UPLINK="$(ip -4 route show "$LAN" 2>/dev/null | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)"
    [ -n "$UPLINK" ] || UPLINK="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
    if [ -n "$UPLINK" ]; then
      nft add rule ip qubes custom-dnat-guivnc iifname "$UPLINK" ip saddr "$LAN" tcp dport "$EXT_PORT" ct state new,established,related counter dnat to "${DEST}:${FWD_DPORT}"
      nft add rule ip qubes custom-forward iifname "$UPLINK" ip saddr "$LAN" ip daddr "$DEST" tcp dport "$FWD_DPORT" ct state new,established,related counter accept
    else
      nft add rule ip qubes custom-dnat-guivnc ip saddr "$LAN" tcp dport "$EXT_PORT" ct state new,established,related counter dnat to "${DEST}:${FWD_DPORT}"
      nft add rule ip qubes custom-forward ip saddr "$LAN" ip daddr "$DEST" tcp dport "$FWD_DPORT" ct state new,established,related counter accept
    fi
  done
{%- else %}
  ip neigh flush to "$DEST" 2>/dev/null || true
  for d in $(ip -o link show | sed -n 's/^[0-9]*: \(vif[0-9.]*\).*/\1/p'); do
    ip neigh del "$DEST" dev "$d" 2>/dev/null || true
  done
  SELF="$(ip -4 route get {{ web_ip }} 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p')"
  [ -n "$SELF" ] || SELF="{{ sysfw_ip }}"
  nft add rule ip qubes custom-dnat-guivnc ip daddr "$SELF" tcp dport "$EXT_PORT" ct state new,established,related counter dnat to "${DEST}:${FWD_DPORT}"
  nft add rule ip qubes custom-forward ip daddr "$DEST" tcp dport "$FWD_DPORT" ct state new,established,related counter accept
{%- endif %}
  D=/etc/NetworkManager/dispatcher.d/50-gui-vnc-fw
  if [ -d /etc/NetworkManager/dispatcher.d ]; then
    printf '%s\n' '#!/bin/sh' 'case "$2" in' '  up|dhcp4-change|dhcp6-change)' '    [ -x /rw/config/qubes-firewall-user-script ] && /rw/config/qubes-firewall-user-script ;;' 'esac' > "$D"
    chmod 0755 "$D"
  fi
  printf '%s netfw: dnat=%s forward=%s\n' "$(date -Is)" \
    "$(nft list chain ip qubes custom-dnat-guivnc 2>/dev/null | grep -c 'dnat to')" \
    "$(nft list chain ip qubes custom-forward 2>/dev/null | grep -c 'accept')" \
    >> /rw/config/gui-vnc-boot.log 2>/dev/null || true
fi
# <<< gui-vnc <<<
{%- endmacro %}

{#- The two-hop model only holds when the web qube's netvm is itself a direct
    child of sys-net. If it is behind another hop (e.g. sys-tailscale), these
    rules would be silently wrong, so fail loudly instead of installing them. -#}
{%- set netvm_parent = salt['cmd.run']('qvm-prefs ' ~ sysfw ~ ' netvm 2>/dev/null', python_shell=True).strip() %}
{% if netvm_parent != sysnet %}

"gui-vnc-netfw-bad-chain":
  test.fail_without_changes:
    - name: |
        mgmt.gui-vnc.netfw assumes the LAN path sys-net -> {{ sysfw }} -> {{ qube }},
        but {{ sysfw }}'s own netvm is '{{ netvm_parent }}', not {{ sysnet }}.
        Set cfg.gui_vnc.web.netvm = sys-firewall, or stop port-forwarding by
        setting cfg.gui_vnc.web.network to something other than "portforward".
    - failhard: True

{% else %}

{% for hop in [sysnet, sysfw] %}
{%   set persist = salt['cmd.run']("qvm-volume info " ~ hop ~ ":private 2>/dev/null | awk '/^save_on_stop/{print $2}'", python_shell=True).strip() %}
{%   set dvmtpl = salt['cmd.run']('qvm-prefs ' ~ hop ~ ' template 2>/dev/null', python_shell=True).strip() %}
{%   set store = hop if (persist == 'True' or not dvmtpl) else dvmtpl %}
{%   set script = fw_script('sys-net' if hop == sysnet else 'sys-firewall', hop) %}
{%   set staged = '/tmp/gui-vnc-fw-' ~ hop ~ '.sh' %}
{%   set merge = 'F=/rw/config/qubes-firewall-user-script; touch "$F"; grep -q "^#!" "$F" || sed -i "1i #!/bin/sh" "$F"; sed -i "/# >>> gui-vnc/,/# <<< gui-vnc <<</d" "$F"; cat >> "$F"; chmod 0755 "$F"' %}

"gui-vnc-netfw-stage-{{ hop }}":
  file.managed:
    - name: {{ staged }}
    - mode: '0644'
    - contents: |
        {{ script | indent(8) }}

"gui-vnc-netfw-write-{{ hop }}":
  cmd.run:
    - name: |
        cat {{ staged }} | qvm-run --pass-io -u root -- {{ hop }} '{{ merge }}'
    - onlyif: qvm-check --running {{ hop }}
    - require:
      - file: "gui-vnc-netfw-stage-{{ hop }}"

"gui-vnc-netfw-apply-{{ hop }}":
  cmd.run:
    - name: qvm-run --pass-io -u root -- {{ hop }} /rw/config/qubes-firewall-user-script
    - onlyif: qvm-check --running {{ hop }}
    - require:
      - cmd: "gui-vnc-netfw-write-{{ hop }}"

{% if store != hop %}
"gui-vnc-netfw-persist-{{ hop }}":
  cmd.run:
    - name: |
        cat {{ staged }} | qvm-run --pass-io -u root -- {{ store }} '{{ merge }}'
    - require:
      - cmd: "gui-vnc-netfw-apply-{{ hop }}"

"gui-vnc-netfw-persist-commit-{{ hop }}":
  cmd.run:
    - name: qvm-shutdown --wait {{ store }}
    - require:
      - cmd: "gui-vnc-netfw-persist-{{ hop }}"
{% endif %}

{% endfor %}

{% endif %}{# netvm_parent == sysnet #}

{% endif %}
