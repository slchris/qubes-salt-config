{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Create the browser front-end qube and its template (runs IN dom0).

A dedicated networked AppVM whose only job is to carry KasmVNC's HTTPS/WebSocket
stream on one side and the GUI domain's qrexec tunnel on the other. It is kept
separate from the GUI domain (which must have no netvm) and from mgmt-jump
(which terminates inbound SSH and should stay single-purpose).

The template is cloned from cfg.gui_vnc.web.template_source with the repo's
clone_template macro; mgmt.gui-vnc.web-install adds socat to it. The GUI domain
serves KasmVNC's own HTTPS/WebSocket client, so this qube only forwards raw
TCP. This state writes the ONLY qrexec hole the front end needs: permission to
call qubes.ConnectTCP on the GUI domain's KasmVNC port.

Deploy (from dom0):
  sudo qubesctl state.apply mgmt.gui-vnc.web-create
#}

{%- from 'config.jinja' import cfg with context -%}
{%- from 'utils/macros/clone-template.sls' import clone_template -%}
{%- from "qvm/template.jinja" import load -%}
{%- set gv = cfg.get('gui_vnc', {}) -%}
{%- set web = gv.get('web', {}) -%}
{%- set gui_qube = gv.get('qube', 'sys-gui-vnc') -%}
{%- set kasm_port = web.get('kasm_port', 8444) -%}
{%- set web_tpl = web.get('template', 'tpl-gui-vnc-web') -%}
{%- set web_name = web_tpl[4:] if web_tpl.startswith('tpl-') else web_tpl -%}
{%- set web_qube = web.get('qube', 'sys-vncweb') -%}

{% if grains['nodename'] == 'dom0' %}
{% if gv.get('enabled', False) and web.get('enabled', False) %}

{{ clone_template(web.get('template_source', 'debian-minimal'), web_name) }}

{% load_yaml as defaults -%}
name: {{ web_qube }}
force: True
require:
- qvm: {{ web_tpl }}-clone
present:
- template: {{ web_tpl }}
- label: {{ web.get('label', 'orange') }}
prefs:
- template: {{ web_tpl }}
- label: {{ web.get('label', 'orange') }}
- netvm: {{ web.get('netvm', 'sys-firewall') }}
- provides_network: False
- audiovm: ""
- memory: {{ web.get('memory', 400) }}
- maxmem: {{ web.get('maxmem', 1500) }}
- vcpus: {{ web.get('vcpus', 2) }}
- autostart: True
{%- endload %}
{{ load(defaults) }}

# The single qrexec hole: only the front-end qube may open qubes.ConnectTCP to
# the GUI domain's KasmVNC web port. Everything else is denied.
"gui-vnc-web-connecttcp-policy":
  file.managed:
    - name: /etc/qubes/policy.d/50-gui-vnc-web.policy
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        # SPDX-License-Identifier: MIT
        # Managed by mgmt.gui-vnc.web-create.
        # Allow ONLY {{ web_qube }} to reach {{ gui_qube }}'s KasmVNC web server.
        qubes.ConnectTCP +{{ kasm_port }} {{ web_qube }} {{ gui_qube }} allow
        qubes.ConnectTCP *     {{ web_qube }} @anyvm deny

{% else %}

"gui-vnc-web-create-disabled-note":
  test.show_notification:
    - text: |
        mgmt.gui-vnc.web-create: gui_vnc/web.enabled is False — not creating
        {{ web_qube }}.

{% endif %}
{% endif %}
