{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Create IM qubes (tpl-im, im) for instant messaging
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
- maxmem: 2000
- include_in_backups: True
features:
- set:
  - menu-items: "signal-desktop.desktop element-desktop.desktop qubes-run-terminal.desktop qubes-start.desktop"
  - default-menu-items: "signal-desktop.desktop element-desktop.desktop qubes-run-terminal.desktop qubes-start.desktop"
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
- maxmem: 2000
- include_in_backups: True
{%- endload %}
{{ load(defaults) }}
