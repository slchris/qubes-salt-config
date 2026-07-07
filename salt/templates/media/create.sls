{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Create media qubes (tpl-media, dvm-media) for multimedia playback
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
- label: yellow
- audiovm: ""
- vcpus: 2
- memory: 400
- maxmem: 4000
- include_in_backups: True
features:
- set:
  - menu-items: "vlc.desktop mpv.desktop qubes-open-file-manager.desktop qubes-run-terminal.desktop qubes-start.desktop"
  - default-menu-items: "vlc.desktop mpv.desktop qubes-open-file-manager.desktop qubes-run-terminal.desktop qubes-start.desktop"
{%- endload %}
{{ load(defaults) }}

{% load_yaml as defaults -%}
name: dvm-{{ name }}
force: True
require:
- qvm: tpl-{{ name }}
present:
- template: tpl-{{ name }}
- label: yellow
prefs:
- template: tpl-{{ name }}
- label: yellow
- netvm: ""
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
  - menu-items: "vlc.desktop mpv.desktop qubes-open-file-manager.desktop qubes-run-terminal.desktop qubes-start.desktop"
{%- endload %}
{{ load(defaults) }}
