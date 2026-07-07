{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Create tools qubes (tpl-tools, dvm-tools) for general utilities
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
- label: purple
- audiovm: ""
- vcpus: 2
- memory: 400
- maxmem: 4000
- include_in_backups: True
features:
- set:
  - menu-items: "qubes-open-file-manager.desktop qubes-run-terminal.desktop qubes-start.desktop"
  - default-menu-items: "qubes-open-file-manager.desktop qubes-run-terminal.desktop qubes-start.desktop"
{%- endload %}
{{ load(defaults) }}

{% load_yaml as defaults -%}
name: dvm-{{ name }}
force: True
require:
- qvm: tpl-{{ name }}
present:
- template: tpl-{{ name }}
- label: purple
prefs:
- template: tpl-{{ name }}
- label: purple
- audiovm: ""
- vcpus: 2
- memory: 400
- maxmem: 4000
- template_for_dispvms: True
- include_in_backups: False
features:
- enable:
  - appmenus-dispvm
- set:
  - menu-items: "qubes-open-file-manager.desktop qubes-run-terminal.desktop qubes-start.desktop"
{%- endload %}
{{ load(defaults) }}
