{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Create Gentoo development qubes (tpl-gentoo-dev, gentoo-dev) for ebuild and
package development. Networked so emerge can fetch distfiles. Compiling from
source is CPU/RAM heavy, so these qubes get more vcpus/memory.
#}

{%- from "qvm/template.jinja" import load -%}
{% from 'config.jinja' import cfg with context -%}
{% set name = slsdotpath.split('.')[-1] %}
{% set dev = cfg.qvm.get('gentoo', {}).get('dev', {}) -%}

include:
  - {{ slsdotpath }}.clone

{# The template itself doesn't compile — it just holds the toolchain — so keep
   it light. The gentoo-dev AppVM below is where emerge runs and gets the beef. #}
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

{# gentoo-dev AppVM — resources from cfg.qvm.gentoo.dev so they track the host.
   maxmem 0 disables the balloon (fixed memory) so a big -jN emerge won't OOM. #}
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
- vcpus: {{ dev.get('vcpus', 4) }}
- memory: {{ dev.get('memory', 2000) }}
- maxmem: {{ dev.get('maxmem', 0) }}
- include_in_backups: True
{%- endload %}
{{ load(defaults) }}
