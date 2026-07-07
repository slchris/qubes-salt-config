{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Create VPN qubes (tpl-vpn, sys-vpn)
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
- label: orange
- audiovm: ""
- memory: 300
- maxmem: 600
- include_in_backups: True
features:
- set:
  - menu-items: "qubes-run-terminal.desktop qubes-start.desktop"
  - default-menu-items: "qubes-run-terminal.desktop qubes-start.desktop"
{%- endload %}
{{ load(defaults) }}

{% load_yaml as defaults -%}
name: sys-{{ name }}
force: True
require:
- qvm: tpl-{{ name }}
present:
- template: tpl-{{ name }}
- label: orange
prefs:
- template: tpl-{{ name }}
- label: orange
- netvm: sys-firewall
- audiovm: ""
- memory: 300
- maxmem: 600
- provides-network: True
- autostart: False
- include_in_backups: True
features:
- enable:
  - servicevm
{%- endload %}
{{ load(defaults) }}
