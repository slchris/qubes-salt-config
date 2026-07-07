{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Create management qubes (tpl-mgmt, dvm-mgmt)

Note: tpl-mgmt uses dvm-fedora as its management_dispvm during bootstrap.
fedora (full) has polkit configured for passwordless sudo, unlike fedora-minimal.
After mgmt.prefs is applied, the global management_dispvm becomes dvm-mgmt.
#}

{%- from "qvm/template.jinja" import load -%}

include:
  - {{ slsdotpath }}.clone
  - fedora-minimal.prefs

{% load_yaml as defaults -%}
name: tpl-{{ slsdotpath }}
force: True
require:
- sls: {{ slsdotpath }}.clone
- sls: fedora-minimal.prefs
prefs:
- label: black
- netvm: ""
- audiovm: ""
- memory: 300
- maxmem: 600
- vcpus: 1
- include_in_backups: False
- management_dispvm: dvm-fedora
features:
- set:
  - menu-items: "qubes-run-terminal.desktop qubes-start.desktop"
{%- endload %}
{{ load(defaults) }}

{% load_yaml as defaults -%}
name: dvm-{{ slsdotpath }}
force: True
require:
- qvm: tpl-{{ slsdotpath }}
present:
- template: tpl-{{ slsdotpath }}
- label: black
prefs:
- template: tpl-{{ slsdotpath }}
- label: black
- netvm: ""
- audiovm: ""
- memory: 300
- maxmem: 600
- vcpus: 1
- template_for_dispvms: True
- include_in_backups: False
features:
- enable:
  - appmenus-dispvm
  - internal
{%- endload %}
{{ load(defaults) }}

