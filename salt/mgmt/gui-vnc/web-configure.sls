{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Configure the KasmVNC web proxy inside the front-end qube.

The GUI domain runs KasmVNC's Xvnc on :1 and mirrors the real Qubes GUI
display (:0) onto it with kasmxproxy. KasmVNC serves its own HTTPS/WebSocket
web client on localhost:8444 inside the GUI domain. This qube only carries the
raw TCP stream over qrexec and exposes it on the LAN via the existing 6080
DNAT:

  browser --https--> sys-vncweb:6080 --socat--> qrexec ConnectTCP+8444
          --> sys-gui-vnc:8444 KasmVNC web server

There is no noVNC/websockify anymore. The Qubes app menu, Qubes Manager and
all qube windows are part of the mirrored :0 display, so the browser session
has the same Qubes GUI functionality as the old noVNC session.

Deploy (from dom0), after web-install and with the qube started:
  sudo qubesctl --skip-dom0 --targets=<web qube> state.apply mgmt.gui-vnc.web-configure
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set gv = cfg.get('gui_vnc', {}) -%}
{%- set web = gv.get('web', {}) -%}
{%- set gui_qube = gv.get('qube', 'sys-gui-vnc') -%}
{%- set kasm_port = web.get('kasm_port', 8444) -%}
{%- set listen = web.get('listen', '0.0.0.0:6080') -%}
{%- set listen_port = listen.split(':')[-1] -%}
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
        # KasmVNC serves HTTPS and its WebSocket client on one port; tunnel the
        # raw TCP stream, not a noVNC WebSocket-to-VNC translation.
        exec /usr/bin/qrexec-client-vm {{ gui_qube }} qubes.ConnectTCP+{{ kasm_port }}

"gui-vnc-web-unit":
  file.managed:
    - name: {{ dir }}/qubes-gui-vnc-web.service
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        [Unit]
        Description=KasmVNC TCP proxy -> {{ gui_qube }}:{{ kasm_port }} over qrexec
        After=qubes-qrexec-agent.service
        [Service]
        Type=simple
        ExecStart=/usr/bin/socat TCP-LISTEN:{{ listen_port }},bind=0.0.0.0,fork,reuseaddr,nodelay EXEC:{{ dir }}/attach.sh
        Restart=always
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
        install -m 0644 {{ dir }}/qubes-gui-vnc-web.service /etc/systemd/system/qubes-gui-vnc-web.service
        systemctl daemon-reload
        systemctl disable --now qubes-gui-vnc-bridge.service 2>/dev/null || true
        rm -f /etc/systemd/system/qubes-gui-vnc-bridge.service
        systemctl enable --now qubes-gui-vnc-web.service
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
        install -m 0644 {{ dir }}/qubes-gui-vnc-web.service /etc/systemd/system/qubes-gui-vnc-web.service
        systemctl daemon-reload
        systemctl disable --now qubes-gui-vnc-bridge.service 2>/dev/null || true
        rm -f /etc/systemd/system/qubes-gui-vnc-bridge.service
        systemctl enable qubes-gui-vnc-web.service
        systemctl restart qubes-gui-vnc-web.service
{%- if network == 'portforward' %}
        nft list chain ip qubes custom-input 2>/dev/null | grep -q 'tcp dport {{ ext_port }}' \
          || nft add rule ip qubes custom-input tcp dport {{ ext_port }} ct state new,established,related counter accept 2>/dev/null || true
{%- endif %}
    - require:
      - file: "gui-vnc-web-attach"
      - file: "gui-vnc-web-unit"

{% else %}

"gui-vnc-web-configure-disabled-note":
  test.show_notification:
    - text: |
        mgmt.gui-vnc.web-configure: gui_vnc/web.enabled is False — nothing to do.

{% endif %}
{% endif %}
