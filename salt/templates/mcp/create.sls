{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Create MCP development qubes (tpl-mcp, dvm-mcp, mcp) for building MCP servers
and AI applications that call model APIs. Networked (API calls, package pulls).
#}

{%- from "qvm/template.jinja" import load -%}
{% set name = slsdotpath.split('.')[-1] %}

include:
  - {{ slsdotpath }}.clone

{% load_yaml as defaults -%}
name: tpl-{{ name }}
force: True
require:
- sls: {{ slsdotpath }}.clone
prefs:
- label: blue
- audiovm: ""
- vcpus: 2
- memory: 400
- maxmem: 6000
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
present:
- template: tpl-{{ name }}
- label: blue
prefs:
- template: tpl-{{ name }}
- label: blue
- audiovm: ""
- vcpus: 2
- memory: 400
- maxmem: 6000
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
present:
- template: tpl-{{ name }}
- label: blue
prefs:
- template: tpl-{{ name }}
- label: blue
- audiovm: ""
- vcpus: 2
- memory: 400
- maxmem: 6000
- include_in_backups: True
{%- endload %}
{{ load(defaults) }}
