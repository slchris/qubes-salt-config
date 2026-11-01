{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Create tpl-agents: the shared template for multi-agent development qubes.

It has no netvm (templates never do). The agents and their Node runtime arrive
through agents.deliver, which copies a verified bundle from agent-build into
this template; nothing here downloads at runtime. Project AppVMs are created
from this template and get their own netvm separately.

Credentials and agent configurations (~/.claude, ~/.codex, ~/.config/opencode,
...) live in each AppVM's private volume, never in this template.
#}

{% from 'config.jinja' import cfg with context %}
{% import_yaml 'agents/lock.yml' as lock %}
{%- from "qvm/template.jinja" import load -%}
{% set t = cfg.agents.template %}
{% set gui_desktops = lock.get('gui_apps', {}).values() | map(attribute='desktop_file') | select | join(' ') %}

include:
  - agents.template.clone

{% load_yaml as defaults -%}
name: {{ t.name }}
force: True
require:
- sls: agents.template.clone
prefs:
- label: {{ t.label }}
- audiovm: ""
- vcpus: {{ t.vcpus }}
- memory: {{ t.memory }}
- maxmem: {{ t.maxmem }}
- include_in_backups: True
features:
- set:
  - menu-items: "qubes-run-terminal.desktop qubes-start.desktop {{ gui_desktops }}"
  - default-menu-items: "qubes-run-terminal.desktop qubes-start.desktop {{ gui_desktops }}"
{%- endload %}
{{ load(defaults) }}
