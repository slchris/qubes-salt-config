{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

GUI-domain health check (runs IN dom0).

Installs a small probe + systemd timer that detects a wedged GUI domain and
recovers it automatically. This is what prevents the failure seen on the
reference machine: a kasmxproxy segfault froze sys-gui-vnc's qrexec agent, every
qube's windows stopped rendering, and qvm-shutdown could not stop it — for days.

The probe runs `qvm-run --no-gui <guivm> true` under a timeout. A healthy GUI
domain answers at once; a wedged one hangs. After cfg.gui_vnc.healthcheck
fail_threshold consecutive failures the timer's script qvm-kills the GUI domain,
starts it again, and restarts the running AppVMs so their gui-agent reconnects
to the fresh GUI session.

Opt-in via cfg.gui_vnc.healthcheck.enabled (default True when gui_vnc is on).
Deploy (from dom0):
  sudo qubesctl state.apply mgmt.gui-vnc.healthcheck
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set gv = cfg.get('gui_vnc', {}) -%}
{%- set hc = gv.get('healthcheck', {}) -%}
{%- set qube = gv.get('qube', 'sys-gui-vnc') -%}
{%- set probe_timeout = hc.get('probe_timeout', '20s') -%}
{%- set fail_threshold = hc.get('fail_threshold', 3) -%}
{%- set interval = hc.get('interval', '5min') -%}
{%- set state_dir = '/var/lib/gui-vnc-healthcheck' -%}

{% if grains['nodename'] == 'dom0' %}
{% if gv.get('enabled', False) and hc.get('enabled', True) %}

"gui-vnc-healthcheck-script":
  file.managed:
    - name: /usr/local/sbin/gui-vnc-healthcheck
    - source: salt://mgmt/gui-vnc/files/kasm/healthcheck.sh
    - template: jinja
    - context:
        qube: {{ qube }}
        probe_timeout: {{ probe_timeout }}
        fail_threshold: {{ fail_threshold }}
        state_dir: {{ state_dir }}
    - user: root
    - group: root
    - mode: '0755'
    - makedirs: True

"gui-vnc-healthcheck-dir":
  file.directory:
    - name: {{ state_dir }}
    - user: root
    - group: root
    - mode: '0700'

"gui-vnc-healthcheck-service":
  file.managed:
    - name: /etc/systemd/system/gui-vnc-healthcheck.service
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        # SPDX-License-Identifier: MIT
        [Unit]
        Description=GUI-domain (VNC) health probe and auto-recovery
        After=qubesd.service

        [Service]
        Type=oneshot
        ExecStart=/usr/local/sbin/gui-vnc-healthcheck
        Nice=10
    - require:
      - file: gui-vnc-healthcheck-script

"gui-vnc-healthcheck-timer":
  file.managed:
    - name: /etc/systemd/system/gui-vnc-healthcheck.timer
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        # SPDX-License-Identifier: MIT
        [Unit]
        Description=Periodic GUI-domain (VNC) health check

        [Timer]
        OnBootSec=2min
        OnUnitActiveSec={{ interval }}
        AccuracySec=1min
        Persistent=false

        [Install]
        WantedBy=timers.target
    - require:
      - file: gui-vnc-healthcheck-service

"gui-vnc-healthcheck-enable":
  cmd.run:
    - name: systemctl daemon-reload && systemctl enable --now gui-vnc-healthcheck.timer
    - runas: root
    - unless: systemctl is-enabled --quiet gui-vnc-healthcheck.timer && systemctl is-active --quiet gui-vnc-healthcheck.timer
    - require:
      - file: gui-vnc-healthcheck-timer

{% else %}

"gui-vnc-healthcheck-note":
  test.show_notification:
    - text: |
        mgmt.gui-vnc.healthcheck: disabled (gui_vnc.enabled False or
        gui_vnc.healthcheck.enabled False) — not installing the timer.

{% endif %}
{% endif %}
