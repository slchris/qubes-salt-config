{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Sync Appmenus macro - synchronizes application menus for templates

Usage:
{% from 'utils/macros/sync-appmenus.sls' import sync_appmenus -%}
{{ sync_appmenus('tpl-dev') }}
#}

{% macro sync_appmenus(target) -%}
"{{ target }}-sync-appmenus":
  cmd.run:
    - name: qvm-sync-appmenus {{ target }}
    - runas: user
{%- endmacro %}

{#
Macro to set specific menu items for a template.
Usage:
{% from 'utils/macros/sync-appmenus.sls' import set_menu_items -%}
{{ set_menu_items('tpl-dev', 'qubes-run-terminal.desktop qubes-start.desktop') }}
#}

{% macro set_menu_items(target, items) -%}
"{{ target }}-set-menu-items":
  qvm.features:
    - name: {{ target }}
    - set:
      - menu-items: "{{ items }}"
      - default-menu-items: "{{ items }}"
{%- endmacro %}
