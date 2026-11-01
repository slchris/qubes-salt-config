{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Three-hop LAN forward onto each published profile project qube. Runs in
dom0. No-op while cfg.magpie.enabled is False.

  LAN client -> sys-net:<port> -> <netvm of the profile netvm>:<port>
             -> <profile netvm>:<port> -> <profile project qube>:<port>

slchris today is sys-net -> sys-firewall -> sys-bwg-mullvad ->
slchris-project. The states follow cfg.profiles, so a second profile with
its own netvm gets its own port and its own last hop. This does not create
a qube and does not change any netvm.

Same DNAT+SNAT rules as mgmt.gui-vnc.netfw, one hop further. Read that
file for the boot-order and DispVM rules. Chains are custom-dnat-magpie
and custom-snat-magpie. remote-debug and gui-vnc chains are not touched.
There is no kill-switch exception: project-net still drops new vif*
traffic that is not going to wg0.

Source filter on sys-net is cfg.remote_debug.lan_subnet. The later hops
accept the port only from their own Qubes gateway, which is the previous
hop after that hop's SNAT. Re-apply when a published qube or a hop is
recreated and its IP changes. sys-net, the middle hop, and the profile
netvm must be running. A disposable middle hop (sys-firewall on this
host) persists the block into its DVM template, and that template is shut
down afterwards. Paused disposables named disp plus digits on that
template are unpaused and shut down first. sys-firewall and sys-usb are
left running.

Apply:
  sudo qubesctl state.apply magpie.netfw
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set mg = cfg.magpie -%}
{%- set sysnet = 'sys-net' -%}
{%- set reserved = [22, 2333, 6080, 8080, 8443, 8444, 18080] -%}
{%- set blocked_netvm = ['', 'none', 'None', 'sys-net', 'sys-firewall'] -%}

{%- macro bad_token(value) -%}
{%- set v = value | string -%}
{%- if v == '' or ' ' in v or '/' in v or '"' in v or "'" in v or '$' in v or '`' in v or ';' in v or '|' in v or '&' in v or '\\' in v -%}
yes
{%- endif -%}
{%- endmacro -%}

{%- macro ipv4(value) -%}
{%- set parts = (value | string).split('.') -%}
{%- if parts | length == 4 -%}
{%- set okt = namespace(ok=True) -%}
{%- for o in parts -%}
{%- if o | length < 1 or o | length > 3 or o | int(-1) < 0 or o | int(-1) > 255 or (o | int(-1) | string) != o -%}
{%- set okt.ok = False -%}
{%- endif -%}
{%- endfor -%}
{%- if okt.ok -%}yes{%- endif -%}
{%- endif -%}
{%- endmacro -%}

{%- macro fw_script(qname, self_ip, items, lans) -%}
# >>> magpie (managed by magpie.netfw — do not edit) >>>
# NEVER exit from this block. The firewall script is shared with other
# formulas, and it runs before a DHCP lease exists.
MG_SELF="$(qubesdb-read /name 2>/dev/null || true)"
if [ "$MG_SELF" != "{{ qname }}" ]; then
  : # inherited by a sibling disposable from the shared DVM template
else
  nft delete chain ip qubes custom-dnat-magpie 2>/dev/null || true
  nft delete chain ip qubes custom-snat-magpie 2>/dev/null || true
  nft add chain ip qubes custom-dnat-magpie '{ type nat hook prerouting priority -99 ; policy accept ; }'
  nft add chain ip qubes custom-snat-magpie '{ type nat hook postrouting priority 99 ; policy accept ; }'
  add_one() {
    PORT="$1"
    DEST="$2"
    KIND="$3"
    nft add rule ip qubes custom-snat-magpie ip daddr "$DEST" tcp dport "$PORT" counter masquerade
    nft -a list chain ip qubes custom-forward 2>/dev/null \
      | grep -F "ip daddr $DEST" | grep -F "tcp dport $PORT" \
      | grep -o 'handle [0-9]*' | awk '{print $2}' \
      | while read -r h; do nft delete rule ip qubes custom-forward handle "$h" 2>/dev/null || true; done
    if [ "$KIND" = lan ]; then
      for LAN in {{ lans | join(' ') }}; do
        UPLINK="$(ip -4 route show "$LAN" 2>/dev/null | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)"
        [ -n "$UPLINK" ] || UPLINK="$(ip -4 route show default 2>/dev/null | awk 'NR==1 {print $5}')"
        if [ -n "$UPLINK" ]; then
          nft add rule ip qubes custom-dnat-magpie iifname "$UPLINK" ip saddr "$LAN" tcp dport "$PORT" ct state new,established,related counter dnat to "${DEST}:${PORT}"
          nft add rule ip qubes custom-forward iifname "$UPLINK" ip saddr "$LAN" ip daddr "$DEST" tcp dport "$PORT" ct state new,established,related counter accept
        else
          nft add rule ip qubes custom-dnat-magpie ip saddr "$LAN" tcp dport "$PORT" ct state new,established,related counter dnat to "${DEST}:${PORT}"
          nft add rule ip qubes custom-forward ip saddr "$LAN" ip daddr "$DEST" tcp dport "$PORT" ct state new,established,related counter accept
        fi
      done
    else
      ip neigh flush to "$DEST" 2>/dev/null || true
      for d in $(ip -o link show | sed -n 's/^[0-9]*: \(vif[0-9.]*\).*/\1/p'); do
        ip neigh del "$DEST" dev "$d" 2>/dev/null || true
      done
      SELF="$(ip -4 route get "$DEST" 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p')"
      [ -n "$SELF" ] || SELF="{{ self_ip }}"
      GW="$(qubesdb-read /qubes-gateway 2>/dev/null || true)"
      if [ -n "$GW" ] && [ -n "$SELF" ]; then
        nft add rule ip qubes custom-dnat-magpie ip saddr "$GW" ip daddr "$SELF" tcp dport "$PORT" ct state new,established,related counter dnat to "${DEST}:${PORT}"
        nft add rule ip qubes custom-forward ip saddr "$GW" ip daddr "$DEST" tcp dport "$PORT" ct state new,established,related counter accept
      else
        echo "magpie: gateway or self address empty on {{ qname }} port $PORT" >&2
      fi
    fi
  }
{% for item in items %}
  add_one {{ item.port }} {{ item.dest }} {{ item.kind }}
{% endfor %}
  D=/etc/NetworkManager/dispatcher.d/50-magpie-fw
  if [ -d /etc/NetworkManager/dispatcher.d ]; then
    printf '%s\n' '#!/bin/sh' 'case "$2" in' '  up|dhcp4-change|dhcp6-change)' '    [ -x /rw/config/qubes-firewall-user-script ] && /rw/config/qubes-firewall-user-script ;;' 'esac' > "$D"
    chmod 0755 "$D"
  fi
  printf '%s netfw: dnat=%s forward=%s\n' "$(date -Is)" \
    "$(nft list chain ip qubes custom-dnat-magpie 2>/dev/null | grep -c 'dnat to')" \
    "$(nft list chain ip qubes custom-forward 2>/dev/null | grep -c 'accept')" \
    >> /rw/config/magpie-boot.log 2>/dev/null || true
fi
# <<< magpie <<<
{%- endmacro -%}

{% if grains['nodename'] == 'dom0' and mg.enabled %}

{%- set ns = namespace(errors=[], ports=[], projects=[]) -%}
{%- if not mg.services -%}
{%- set _ = ns.errors.append('cfg.magpie.services is empty') -%}
{%- endif -%}
{%- for name, svc in mg.services.items() -%}
{%- set profile = cfg.profiles.get(name) -%}
{%- set port_s = svc.port | string -%}
{%- set port_i = port_s | int(-1) -%}
{%- if profile is none -%}
{%- set _ = ns.errors.append(name ~ ' is not a profile') -%}
{%- else -%}
{%- set project = profile.project | string -%}
{%- set netvm = profile.netvm | string -%}
{%- if port_s != (port_i | string) or port_i < 1 or port_i > 65535 or port_i in reserved or port_i in ns.ports -%}
{%- set _ = ns.errors.append(name ~ ' port ' ~ port_s ~ ' is invalid, reserved, or duplicated') -%}
{%- endif -%}
{%- set _ = ns.ports.append(port_i) -%}
{%- if (bad_token(project) | trim) == 'yes' or (bad_token(netvm) | trim) == 'yes' -%}
{%- set _ = ns.errors.append(name ~ ' has an unusable project or netvm name') -%}
{%- elif netvm in blocked_netvm or netvm == project -%}
{%- set _ = ns.errors.append(name ~ ' netvm must be that profile gateway, not ' ~ netvm) -%}
{%- elif project in ns.projects -%}
{%- set _ = ns.errors.append(project ~ ' is published by more than one magpie service') -%}
{%- endif -%}
{%- set _ = ns.projects.append(project) -%}
{%- endif -%}
{%- endfor -%}
{%- set lan_raw = cfg.get('remote_debug', {}).get('lan_subnet', '10.31.0.0/24') -%}
{%- set lans = [lan_raw] if lan_raw is string else lan_raw -%}
{%- for lan in lans -%}
{%- if (ipv4(lan.split('/')[0]) | trim) != 'yes' -%}
{%- set _ = ns.errors.append('lan subnet is not usable') -%}
{%- endif -%}
{%- endfor -%}

{% if ns.errors %}

"magpie-netfw-bad-config":
  test.fail_without_changes:
    - name: |
        magpie.netfw refused to install forwards:
        {% for err in ns.errors %}
        {{ err }}
        {% endfor %}
    - failhard: True

{% else %}

{%- set looked = namespace(errors=[], rules=[]) -%}
{%- for name, svc in mg.services.items() -%}
{%- set profile = cfg.profiles[name] -%}
{%- set project = profile.project | string -%}
{%- set hop3 = profile.netvm | string -%}
{%- set got = namespace(project_ip='', live_netvm='', hop3_ip='', hop2='', hop2_ip='', hop1='') -%}
{%- set got.project_ip = salt['cmd.run']('qvm-prefs ' ~ project ~ ' ip 2>/dev/null', python_shell=True).strip() -%}
{%- set got.live_netvm = salt['cmd.run']('qvm-prefs ' ~ project ~ ' netvm 2>/dev/null', python_shell=True).strip() -%}
{%- set got.hop3_ip = salt['cmd.run']('qvm-prefs ' ~ hop3 ~ ' ip 2>/dev/null', python_shell=True).strip() -%}
{%- set got.hop2 = salt['cmd.run']('qvm-prefs ' ~ hop3 ~ ' netvm 2>/dev/null', python_shell=True).strip() -%}
{%- if (bad_token(got.hop2) | trim) != 'yes' and got.hop2 != sysnet and got.hop2 != hop3 -%}
{%- set got.hop2_ip = salt['cmd.run']('qvm-prefs ' ~ got.hop2 ~ ' ip 2>/dev/null', python_shell=True).strip() -%}
{%- set got.hop1 = salt['cmd.run']('qvm-prefs ' ~ got.hop2 ~ ' netvm 2>/dev/null', python_shell=True).strip() -%}
{%- endif -%}
{%- if got.live_netvm != hop3 or got.hop1 != sysnet or (bad_token(got.hop2) | trim) == 'yes' -%}
{%- set _ = looked.errors.append(name ~ ': need sys-net -> middle -> ' ~ hop3 ~ ' -> ' ~ project ~ ', found ' ~ got.hop1 ~ ' -> ' ~ got.hop2 ~ ' -> ' ~ got.live_netvm) -%}
{%- elif (ipv4(got.project_ip) | trim) != 'yes' or (ipv4(got.hop3_ip) | trim) != 'yes' or (ipv4(got.hop2_ip) | trim) != 'yes' -%}
{%- set _ = looked.errors.append(name ~ ': ' ~ project ~ ', ' ~ hop3 ~ ', or ' ~ got.hop2 ~ ' has no usable ip') -%}
{%- else -%}
{%- set _ = looked.rules.append({'hop': sysnet, 'port': svc.port, 'dest': got.hop2_ip, 'kind': 'lan', 'self_ip': got.hop2_ip}) -%}
{%- set _ = looked.rules.append({'hop': got.hop2, 'port': svc.port, 'dest': got.hop3_ip, 'kind': 'relay', 'self_ip': got.hop2_ip}) -%}
{%- set _ = looked.rules.append({'hop': hop3, 'port': svc.port, 'dest': got.project_ip, 'kind': 'relay', 'self_ip': got.hop3_ip}) -%}
{%- endif -%}
{%- endfor -%}

{% if looked.errors %}

"magpie-netfw-bad-chain":
  test.fail_without_changes:
    - name: |
        magpie.netfw refused to install forwards:
        {% for err in looked.errors %}
        {{ err }}
        {% endfor %}
    - failhard: True

{% else %}

{%- set hn = namespace(names=[sysnet]) -%}
{%- for rule in looked.rules -%}
{%- if rule.hop not in hn.names -%}
{%- set _ = hn.names.append(rule.hop) -%}
{%- endif -%}
{%- endfor -%}
{%- set plan = namespace(persists=[]) -%}

{% for hop in hn.names %}
{%- set hr = namespace(items=[], self_ip='') -%}
{%- for rule in looked.rules -%}
{%- if rule.hop == hop -%}
{%- set _ = hr.items.append(rule) -%}
{%- set hr.self_ip = rule.self_ip -%}
{%- endif -%}
{%- endfor -%}
{%- set persist = salt['cmd.run']("qvm-volume info " ~ hop ~ ":private 2>/dev/null | awk '/^save_on_stop/{print $2}'", python_shell=True).strip() -%}
{%- set dvmtpl = salt['cmd.run']('qvm-prefs ' ~ hop ~ ' template 2>/dev/null', python_shell=True).strip() -%}
{%- set store = hop if (persist == 'True' or not dvmtpl) else dvmtpl -%}
{%- set script = fw_script(hop, hr.self_ip, hr.items, lans) -%}
{%- set staged = '/tmp/magpie-fw-' ~ hop ~ '.sh' -%}
{%- set merge = 'F=/rw/config/qubes-firewall-user-script; touch "$F"; grep -q "^#!" "$F" || sed -i "1i #!/bin/sh" "$F"; sed -i "/# >>> magpie/,/# <<< magpie <<</d" "$F"; cat >> "$F"; chmod 0755 "$F"' -%}

"magpie-netfw-stage-{{ hop }}":
  file.managed:
    - name: {{ staged }}
    - mode: '0644'
    - contents: |
        {{ script | indent(8) }}

"magpie-netfw-write-{{ hop }}":
  cmd.run:
    - name: |
        cat {{ staged }} | qvm-run --pass-io -u root -- {{ hop }} '{{ merge }}'
    - onlyif: qvm-check --running {{ hop }}
    - require:
      - file: "magpie-netfw-stage-{{ hop }}"

"magpie-netfw-apply-{{ hop }}":
  cmd.run:
    - name: qvm-run --pass-io -u root -- {{ hop }} /rw/config/qubes-firewall-user-script
    - onlyif: qvm-check --running {{ hop }}
    - require:
      - cmd: "magpie-netfw-write-{{ hop }}"

{% if store != hop %}
"magpie-netfw-clear-paused-{{ store }}":
  cmd.run:
    - name: |
        set -eu
        paused=$(qvm-ls | awk -v tpl="{{ store }}" '$2=="Paused" && $3=="DispVM" && $5==tpl && $1 ~ /^disp[0-9]+$/ {print $1}')
        for q in $paused; do
          qvm-unpause "$q"
          qvm-shutdown --wait "$q"
        done
    - require:
      - cmd: "magpie-netfw-apply-{{ hop }}"

"magpie-netfw-persist-{{ hop }}":
  cmd.run:
    - name: |
        cat {{ staged }} | qvm-run --pass-io -u root -- {{ store }} '{{ merge }}'
    - require:
      - cmd: "magpie-netfw-clear-paused-{{ store }}"
{%- set _ = plan.persists.append({'store': store, 'id': 'magpie-netfw-persist-' ~ hop}) -%}
{% endif %}

{% endfor %}

{%- set seen = namespace(names=[]) -%}
{% for item in plan.persists %}
{% if item.store not in seen.names %}
{%- set reqs = namespace(ids=[]) -%}
{%- for other in plan.persists -%}
{%- if other.store == item.store -%}
{%- set _ = reqs.ids.append(other.id) -%}
{%- endif -%}
{%- endfor -%}
{%- set _ = seen.names.append(item.store) -%}

"magpie-netfw-persist-commit-{{ item.store }}":
  cmd.run:
    - name: qvm-shutdown --wait {{ item.store }}
    - require:
{% for rid in reqs.ids %}
      - cmd: "{{ rid }}"
{% endfor %}

{% endif %}
{% endfor %}

{% endif %}
{% endif %}

{% elif grains['nodename'] == 'dom0' %}

"magpie-netfw-disabled-note":
  test.show_notification:
    - text: "magpie.netfw: cfg.magpie.enabled is False — not installing forwards."

{% endif %}
