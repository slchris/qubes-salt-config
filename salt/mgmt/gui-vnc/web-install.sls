{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Install the browser front-end packages in its TEMPLATE (runs IN the template).

novnc serves the HTML/JS client, websockify translates its WebSocket back to
raw VNC, and socat bridges that to the qrexec tunnel into the GUI domain
(mgmt.gui-vnc.web-configure). Packages live in the template because an AppVM's
root volume is reset on every boot — a per-qube install would vanish.

The template itself is cloned from debian-minimal by mgmt.gui-vnc.web-create.

Deploy (from dom0):
  sudo qubesctl --skip-dom0 --targets=<web template> state.apply mgmt.gui-vnc.web-install
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set gv = cfg.get('gui_vnc', {}) -%}
{%- set web = gv.get('web', {}) -%}

{% if grains['nodename'] != 'dom0' %}
{% if gv.get('enabled', False) and web.get('enabled', False) %}

"gui-vnc-web-update":
  pkg.uptodate:
    - refresh: True

"gui-vnc-web-packages":
  pkg.installed:
    - require:
      - pkg: "gui-vnc-web-update"
    - install_recommends: False
    - skip_suggestions: True
    - pkgs:
      - novnc
      - websockify
      - socat
      # minimal templates ship without the networking agent, so the NIC never
      # comes up and nothing can reach the web listener.
      - qubes-core-agent-networking

{% else %}

"gui-vnc-web-install-disabled-note":
  test.show_notification:
    - text: |
        mgmt.gui-vnc.web-install: gui_vnc/web.enabled is False — skipping the
        browser front-end packages.

{% endif %}
{% endif %}
