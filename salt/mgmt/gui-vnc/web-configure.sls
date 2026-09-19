{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Run the browser front end inside its qube (runs IN the front-end qube).

Two units and the script they share, all persisted under /rw (an AppVM root
volume is reset each boot) and reinstalled from rc.local:

  attach.sh            one qrexec call: open qubes.ConnectTCP+<vnc_port> to the
                       GUI domain, stdio straight through.
  ...-bridge.service   socat TCP-LISTEN:<target_port> -> attach.sh, so the
                       qrexec tunnel appears as a plain loopback TCP port.
  ...-web.service      websockify: serves the noVNC HTML from the distro and
                       translates the browser's WebSocket to that loopback port.

With cfg.gui_vnc.web.network = portforward, rc.local also opens the listen port
in this qube's own firewall (custom-input) so the DNAT from sys-net reaches it.

Deploy (from dom0), after web-install and with the qube started:
  sudo qubesctl --skip-dom0 --targets=<web qube> state.apply mgmt.gui-vnc.web-configure
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set gv = cfg.get('gui_vnc', {}) -%}
{%- set web = gv.get('web', {}) -%}
{%- set gui_qube = gv.get('qube', 'sys-gui-vnc') -%}
{%- set vnc_port = gv.get('vnc_port', 5900) -%}
{%- set listen = web.get('listen', '0.0.0.0:6080') -%}
{%- set target_port = web.get('target_port', 5901) -%}
{%- set network = web.get('network', 'portforward') -%}
{%- set ext_port = web.get('ext_port', 6080) -%}
{%- set dir = '/rw/config/gui-vnc-web' -%}

{% if grains['nodename'] != 'dom0' %}
{% if gv.get('enabled', False) and web.get('enabled', False) %}

"gui-vnc-web-attach":
  file.managed:
    - name: {{ dir }}/attach.sh
    - makedirs: True
    - dir_mode: '0755'
    - user: root
    - group: root
    - mode: '0755'
    - contents: |
        #!/bin/sh
        # SPDX-License-Identifier: MIT — managed by mgmt.gui-vnc.web-configure
        exec /usr/bin/qrexec-client-vm {{ gui_qube }} qubes.ConnectTCP+{{ vnc_port }}

"gui-vnc-web-bridge-unit":
  file.managed:
    - name: {{ dir }}/qubes-gui-vnc-bridge.service
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        [Unit]
        Description=socat bridge: loopback TCP -> {{ gui_qube }} VNC over qrexec
        After=qubes-qrexec-agent.service
        [Service]
        Type=simple
        ExecStart=/usr/bin/socat TCP-LISTEN:{{ target_port }},bind=127.0.0.1,fork,reuseaddr EXEC:{{ dir }}/attach.sh
        Restart=always
        RestartSec=2
        [Install]
        WantedBy=multi-user.target

"gui-vnc-web-websockify-unit":
  file.managed:
    - name: {{ dir }}/qubes-gui-vnc-web.service
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        [Unit]
        Description=noVNC websocket proxy -> {{ gui_qube }} VNC
        After=qubes-gui-vnc-bridge.service
        Wants=qubes-gui-vnc-bridge.service
        [Service]
        Type=simple
        ExecStart=/usr/bin/websockify --web=/usr/share/novnc {{ listen }} 127.0.0.1:{{ target_port }}
        Restart=on-failure
        RestartSec=2
        [Install]
        WantedBy=multi-user.target

"gui-vnc-web-rc-local":
  file.blockreplace:
    - name: /rw/config/rc.local
    - marker_start: "# >>> mgmt.gui-vnc.web >>>"
    - marker_end: "# <<< mgmt.gui-vnc.web <<<"
    - append_if_not_found: True
    - show_changes: True
    - content: |
        install -m 0644 {{ dir }}/qubes-gui-vnc-bridge.service /etc/systemd/system/qubes-gui-vnc-bridge.service
        install -m 0644 {{ dir }}/qubes-gui-vnc-web.service /etc/systemd/system/qubes-gui-vnc-web.service
        systemctl daemon-reload
        systemctl enable --now qubes-gui-vnc-bridge.service qubes-gui-vnc-web.service
{%- if network == 'portforward' %}
        nft list chain ip qubes custom-input 2>/dev/null | grep -q 'tcp dport {{ ext_port }}' \
          || nft add rule ip qubes custom-input tcp dport {{ ext_port }} ct state new,established,related counter accept 2>/dev/null || true
{%- endif %}

"gui-vnc-web-rc-local-shebang":
  cmd.run:
    - name: |
        f=/rw/config/rc.local
        head -n1 "$f" | grep -q '^#!' || sed -i '1i #!/bin/sh' "$f"
        chmod 0755 "$f"
    - require:
      - file: "gui-vnc-web-rc-local"

"gui-vnc-web-apply-now":
  cmd.run:
    - name: |
        install -m 0644 {{ dir }}/qubes-gui-vnc-bridge.service /etc/systemd/system/qubes-gui-vnc-bridge.service
        install -m 0644 {{ dir }}/qubes-gui-vnc-web.service /etc/systemd/system/qubes-gui-vnc-web.service
        systemctl daemon-reload
        systemctl enable --now qubes-gui-vnc-bridge.service qubes-gui-vnc-web.service
{%- if network == 'portforward' %}
        nft list chain ip qubes custom-input 2>/dev/null | grep -q 'tcp dport {{ ext_port }}' \
          || nft add rule ip qubes custom-input tcp dport {{ ext_port }} ct state new,established,related counter accept 2>/dev/null || true
{%- endif %}
    - require:
      - file: "gui-vnc-web-attach"
      - file: "gui-vnc-web-bridge-unit"
      - file: "gui-vnc-web-websockify-unit"

{% else %}

"gui-vnc-web-configure-disabled-note":
  test.show_notification:
    - text: |
        mgmt.gui-vnc.web-configure: gui_vnc/web.enabled is False — nothing to do.

{% endif %}
{% endif %}
