{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Create the AI agent workbench qubes (tpl-ai, dvm-ai, ai).

The persistent `ai` AppVM runs Claude Desktop / Claude Code with the project
code in /home/user/projects (the AppVM private volume — persists across
reboots, include_in_backups). dvm-ai spawns throwaway DispVMs for one-shot
agent runs.

Both are pinned to netvm sys-project-net (templates.project-net), so ALL
their traffic — API calls included — goes through that project's WireGuard
tunnel, fail-closed. This is the only unit in the repo that sets a netvm on
a workstation AppVM; the include + require below guarantee the gateway qube
exists before the pref is set.

IMPORTANT deploy order: fully deploy templates.project-net (install +
configure + wg0.conf) BEFORE first starting `ai` — see that unit's README.

Sizing: Claude Desktop is an Electron app and agent runs are RAM-hungry,
hence maxmem 8000 (vs 6000 for the plain mcp qube).
#}

{%- from "qvm/template.jinja" import load -%}
{% set name = slsdotpath.split('.')[-1] %}

include:
  - {{ slsdotpath }}.clone
  - templates.project-net.create

{% load_yaml as defaults -%}
name: tpl-{{ name }}
force: True
require:
- sls: {{ slsdotpath }}.clone
prefs:
- label: purple
- audiovm: ""
- vcpus: 4
- memory: 400
- maxmem: 8000
- include_in_backups: True
features:
- set:
  - menu-items: "qubes-run-terminal.desktop qubes-start.desktop"
  - default-menu-items: "qubes-run-terminal.desktop qubes-start.desktop"
{%- endload %}
{{ load(defaults) }}

{% load_yaml as defaults -%}
name: dvm-{{ name }}
force: True
require:
- qvm: tpl-{{ name }}
- sls: templates.project-net.create
present:
- template: tpl-{{ name }}
- label: purple
prefs:
- template: tpl-{{ name }}
- label: purple
- netvm: sys-project-net
- audiovm: ""
- vcpus: 4
- memory: 400
- maxmem: 8000
- template_for_dispvms: True
- include_in_backups: False
features:
- enable:
  - appmenus-dispvm
- set:
  - menu-items: "qubes-run-terminal.desktop qubes-start.desktop"
{%- endload %}
{{ load(defaults) }}

{% load_yaml as defaults -%}
name: {{ name }}
force: True
require:
- qvm: tpl-{{ name }}
- sls: templates.project-net.create
present:
- template: tpl-{{ name }}
- label: purple
prefs:
- template: tpl-{{ name }}
- label: purple
- netvm: sys-project-net
- audiovm: ""
- vcpus: 4
- memory: 800
- maxmem: 8000
- include_in_backups: True
features:
- set:
  - menu-items: "claude-desktop.desktop qubes-run-terminal.desktop qubes-start.desktop"
  - default-menu-items: "claude-desktop.desktop qubes-run-terminal.desktop"
{%- endload %}
{{ load(defaults) }}
