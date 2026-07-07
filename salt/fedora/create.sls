{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Create Fedora (full/xfce) template with default settings and dvm
This is the bootstrap template - it has polkit configured for passwordless sudo
#}

{%- from "qvm/template.jinja" import load -%}

{%- import slsdotpath ~ "/template.jinja" as template -%}

include:
  - {{ slsdotpath }}.clone

"dvm-{{ template.template }}-absent":
  qvm.absent:
    - names:
      - {{ template.template_clean }}-dvm
      - {{ template.template }}-dvm

{% load_yaml as defaults -%}
name: {{ template.template }}
force: True
require:
- sls: {{ template.template_clean }}.clone
present:
- label: black
prefs:
- label: black
- audiovm: ""
- memory: 300
- maxmem: 600
- vcpus: 1
- include_in_backups: False
features:
- set:
  - menu-items: "qubes-open-file-manager.desktop qubes-run-terminal.desktop qubes-start.desktop"
  - default-menu-items: "qubes-open-file-manager.desktop qubes-run-terminal.desktop qubes-start.desktop"
{%- endload %}
{{ load(defaults) }}

{% load_yaml as defaults -%}
name: dvm-{{ template.template_clean }}
force: True
require:
- sls: {{ template.template_clean }}.clone
present:
- template: {{ template.template }}
- label: red
prefs:
- template: {{ template.template }}
- label: red
- audiovm: ""
- memory: 300
- maxmem: 400
- vcpus: 1
- template_for_dispvms: True
- include_in_backups: False
features:
- enable:
  - appmenus-dispvm
- set:
  - menu-items: "qubes-open-file-manager.desktop qubes-run-terminal.desktop qubes-start.desktop"
{%- endload %}
{{ load(defaults) }}

{# Set management_dispvm for this template to its own dvm #}
"{{ slsdotpath }}-set-{{ template.template }}-management_dispvm-to-dvm-{{ template.template_clean }}":
  qvm.vm:
    - require:
      - qvm: dvm-{{ template.template_clean }}
    - name: {{ template.template }}
    - prefs:
      - management_dispvm: "dvm-{{ template.template_clean }}"
