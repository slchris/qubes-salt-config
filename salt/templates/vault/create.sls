{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Create vault qubes (tpl-vault, vault) - offline, no network
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
- label: black
- netvm: ""
- audiovm: ""
- memory: 300
- maxmem: 600
- include_in_backups: True
features:
- set:
  - menu-items: "org.keepassxc.KeePassXC.desktop qubes-run-terminal.desktop qubes-start.desktop"
  - default-menu-items: "org.keepassxc.KeePassXC.desktop qubes-run-terminal.desktop qubes-start.desktop"
{%- endload %}
{{ load(defaults) }}

{% load_yaml as defaults -%}
name: {{ name }}
force: True
require:
- qvm: tpl-{{ name }}
present:
- template: tpl-{{ name }}
- label: black
prefs:
- template: tpl-{{ name }}
- label: black
- netvm: ""
- audiovm: ""
- memory: 300
- maxmem: 600
- autostart: False
- include_in_backups: True
{%- endload %}
{{ load(defaults) }}
