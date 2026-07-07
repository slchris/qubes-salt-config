{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Create Gentoo development qubes (tpl-gentoo-dev, gentoo-dev) for ebuild and
package development. Networked so emerge can fetch distfiles. Compiling from
source is CPU/RAM heavy, so these qubes get more vcpus/memory.
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
- vcpus: 4
- memory: 500
- maxmem: 8000
- include_in_backups: True
features:
- set:
  - menu-items: "qubes-run-terminal.desktop qubes-start.desktop"
  - default-menu-items: "qubes-run-terminal.desktop qubes-start.desktop"
{%- endload %}
{{ load(defaults) }}

{% load_yaml as defaults -%}
name: {{ name }}
force: True
require:
- qvm: tpl-{{ name }}
present:
- template: tpl-{{ name }}
- label: orange
prefs:
- template: tpl-{{ name }}
- label: orange
- audiovm: ""
- vcpus: 4
- memory: 500
- maxmem: 8000
- include_in_backups: True
{%- endload %}
{{ load(defaults) }}
