{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Create Gentoo base DVM from an installed Gentoo template.

Requires the Gentoo template to already exist (see gentoo.clone). Gentoo builds
from source, so give the DVM more memory than the minimal debian/fedora bases.
#}

{%- from "qvm/template.jinja" import load -%}

{%- import slsdotpath ~ "/template.jinja" as template -%}

include:
  - {{ slsdotpath }}.clone

{% load_yaml as defaults -%}
name: dvm-{{ template.template_clean }}
force: True
require:
- sls: {{ slsdotpath }}.clone
present:
- template: {{ template.template }}
- label: red
prefs:
- template: {{ template.template }}
- label: red
- audiovm: ""
- memory: 400
- maxmem: 4000
- vcpus: 2
- template_for_dispvms: True
- include_in_backups: False
features:
- enable:
  - appmenus-dispvm
- set:
  - menu-items: "qubes-open-file-manager.desktop qubes-run-terminal.desktop qubes-start.desktop"
{%- endload %}
{{ load(defaults) }}
