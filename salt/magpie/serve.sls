{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Magpie on the profile's existing project qube. No-op while
cfg.magpie.enabled is False, and no-op on any other qube.

MAGPIE_ADDR is that qube's eth0 address, so a forwarded client is not a
loopback peer and magpie requires a gateway key. ip qubes input jumps to
custom-input and then drops, so the gateway source is accepted there.
A separate base chain cannot accept past that policy. The boot path is
rc.local. An ordinary AppVM does not run qubes-firewall-user-script.

The binary is not installed here. The pinned CLI is in
salt/magpie/README.md. The unit looks at /rw/config/magpie/bin/magpie and
then /usr/bin/magpie. Drop the binary in the first path; it survives
without a template change and without restarting the qube. The unit runs
as user so it sees that user's magpie logins. A missing binary exits 0
and stays stopped.

Apply, with the project qube already running:
  sudo qubesctl --skip-dom0 --targets=slchris-project state.apply magpie.serve
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set mg = cfg.magpie -%}
{%- set dir = '/rw/config/magpie' -%}
{%- set reserved = [22, 2333, 6080, 8080, 8443, 8444, 18080] -%}
{%- set blocked_netvm = ['', 'none', 'None', 'sys-net', 'sys-firewall'] -%}
{%- set ns = namespace(errors=[], matched=False, port=0) -%}

{%- macro bad_token(value) -%}
{%- set v = value | string -%}
{%- if v == '' or ' ' in v or '/' in v or '"' in v or "'" in v or '$' in v or '`' in v or ';' in v or '|' in v or '&' in v or '\\' in v -%}
yes
{%- endif -%}
{%- endmacro -%}

{% if mg.enabled %}
{%- set seen_ports = namespace(items=[]) -%}
{%- set seen_projects = namespace(items=[]) -%}
{% for name, svc in mg.services.items() %}
{%- set profile = cfg.profiles.get(name) -%}
{%- set port_s = svc.port | string -%}
{%- set port_i = port_s | int(-1) -%}
{%- if profile is none -%}
{%- set _ = ns.errors.append(name ~ ' is not a profile') -%}
{%- else -%}
{%- set project = profile.project | string -%}
{%- set netvm = profile.netvm | string -%}
{%- if port_s != (port_i | string) or port_i < 1 or port_i > 65535 or port_i in reserved or port_i in seen_ports.items -%}
{%- set _ = ns.errors.append(name ~ ' port ' ~ port_s ~ ' is invalid, reserved, or duplicated') -%}
{%- endif -%}
{%- set _ = seen_ports.items.append(port_i) -%}
{%- if (bad_token(project) | trim) == 'yes' or (bad_token(netvm) | trim) == 'yes' or netvm in blocked_netvm or netvm == project or project in seen_projects.items -%}
{%- set _ = ns.errors.append(name ~ ' project or netvm is not usable') -%}
{%- endif -%}
{%- set _ = seen_projects.items.append(project) -%}
{%- if grains['nodename'] == project -%}
{%- set ns.matched = True -%}
{%- set ns.port = port_i -%}
{%- endif -%}
{%- endif -%}
{% endfor %}
{% endif %}

{% if mg.enabled and ns.matched and ns.errors %}

"magpie-serve-bad-config":
  test.fail_without_changes:
    - name: |
        magpie.serve refused to configure this qube:
        {% for err in ns.errors %}
        {{ err }}
        {% endfor %}
    - failhard: True

{% elif mg.enabled and ns.matched %}

"magpie-serve-bin-dir":
  file.directory:
    - name: {{ dir }}/bin
    - makedirs: True
    - user: user
    - group: user
    - mode: '0755'
    - dir_mode: '0755'

"magpie-serve-script":
  file.managed:
    - name: {{ dir }}/magpie-serve.sh
    - user: root
    - group: root
    - mode: '0755'
    - contents: |
        #!/bin/sh
        # SPDX-License-Identifier: MIT — managed by magpie.serve
        PATH=/usr/sbin:/usr/bin:/sbin:/bin
        export PATH
        if [ -x {{ dir }}/bin/magpie ]; then
          bin={{ dir }}/bin/magpie
        elif [ -x /usr/bin/magpie ]; then
          bin=/usr/bin/magpie
        else
          echo "magpie binary is not installed" >&2
          exit 0
        fi
        ip=$(ip -4 -o addr show dev eth0 | awk '{print $4}' | cut -d/ -f1)
        [ -n "$ip" ] || exit 1
        export HOME=/home/user
        export MAGPIE_ADDR="${ip}:{{ ns.port }}"
        exec "$bin" serve

"magpie-serve-input":
  file.managed:
    - name: {{ dir }}/input.sh
    - user: root
    - group: root
    - mode: '0755'
    - contents: |
        #!/bin/sh
        # SPDX-License-Identifier: MIT — managed by magpie.serve
        # {{ ns.port }} is reachable only from this qube's Qubes gateway.
        PATH=/usr/sbin:/usr/bin:/sbin:/bin
        export PATH
        port={{ ns.port }}
        gw=$(qubesdb-read /qubes-gateway 2>/dev/null || true)
        valid_ip4() {
          case "$1" in *[!0-9.]*|""|.*|*.|*..*) return 1 ;; esac
          _ifs=$IFS; IFS=.; set -- $1; IFS=$_ifs
          [ $# -eq 4 ] || return 1
          for _o in "$1" "$2" "$3" "$4"; do
            [ "$_o" -le 255 ] 2>/dev/null || return 1
          done
        }
        nft delete table inet magpie-local 2>/dev/null || true
        nft add table inet magpie-local
        nft add chain inet magpie-local input '{ type filter hook input priority 0 ; policy accept ; }'
        if valid_ip4 "$gw"; then
          nft add rule inet magpie-local input tcp dport "$port" ip saddr != "$gw" drop
          # custom-input is jumped before the qubes input policy drop.
          nft -a list chain ip qubes custom-input 2>/dev/null \
            | grep -F 'comment "magpie-serve"' \
            | grep -o 'handle [0-9]*' | awk '{print $2}' \
            | while read -r h; do nft delete rule ip qubes custom-input handle "$h" 2>/dev/null || true; done
          nft add rule ip qubes custom-input tcp dport "$port" ip saddr "$gw" accept comment "magpie-serve"
        else
          echo "magpie: /qubes-gateway is empty" >&2
          nft add rule inet magpie-local input tcp dport "$port" drop
          exit 1
        fi

"magpie-serve-unit":
  file.managed:
    - name: {{ dir }}/qubes-magpie.service
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        [Unit]
        Description=Magpie gateway on this profile project qube
        After=qubes-network-uplink@eth0.service
        [Service]
        Type=simple
        User=user
        Group=user
        Environment=HOME=/home/user
        Environment=PATH=/usr/sbin:/usr/bin:/sbin:/bin
        ExecStart={{ dir }}/magpie-serve.sh
        Restart=on-failure
        RestartSec=2
        [Install]
        WantedBy=multi-user.target

"magpie-serve-rc-local":
  file.blockreplace:
    - name: /rw/config/rc.local
    - marker_start: "# >>> magpie.serve >>>"
    - marker_end: "# <<< magpie.serve <<<"
    - append_if_not_found: True
    - show_changes: True
    - content: |
        install -m 0644 {{ dir }}/qubes-magpie.service /etc/systemd/system/qubes-magpie.service
        systemctl daemon-reload
        systemctl enable qubes-magpie.service
        systemctl restart qubes-magpie.service
        {{ dir }}/input.sh

"magpie-serve-rc-local-shebang":
  cmd.run:
    - name: |
        f=/rw/config/rc.local
        head -n1 "$f" | grep -q '^#!' || sed -i '1i #!/bin/sh' "$f"
        chmod 0755 "$f"
    - require:
      - file: magpie-serve-rc-local

"magpie-serve-apply-now":
  cmd.run:
    - name: |
        set -eu
        install -m 0644 {{ dir }}/qubes-magpie.service /etc/systemd/system/qubes-magpie.service
        systemctl daemon-reload
        systemctl enable qubes-magpie.service
        systemctl restart qubes-magpie.service
        {{ dir }}/input.sh
    - require:
      - file: magpie-serve-bin-dir
      - file: magpie-serve-script
      - file: magpie-serve-input
      - file: magpie-serve-unit

{% else %}

"magpie-serve-skip":
  test.show_notification:
    - text: "magpie.serve: this qube is not an enabled profile gateway."

{% endif %}
