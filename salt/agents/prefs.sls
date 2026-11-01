{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Set the app-menu whitelist on existing agent AppVMs (runs IN dom0).

agents.template.create sets the template's menu-items/default-menu-items, but a
TemplateBasedVM keeps its own menu-items feature from creation. An AppVM created
before Chrome/VS Code/Claude Desktop were added therefore shows only the
terminal and start entries even after it is restarted from the new template.

List the agent AppVMs in cfg.agents.qubes and apply:
  sudo qubesctl state.apply agents.prefs

New AppVMs inherit the template's default-menu-items and do not need this. The
state is idempotent. It sets the same whitelist on `tpl-agents` and on the
qubes named in the config.

After the whitelist changes, refresh the dom0 menu for qubes that are already
running. qvm-sync-appmenus has to run as the dom0 user; as root it writes the
entries outside the menu the user actually sees. Halted qubes are left halted.
#}

{% from 'config.jinja' import cfg with context %}
{% import_yaml 'agents/lock.yml' as lock %}
{% from 'utils/macros/sync-appmenus.sls' import set_menu_items %}

{% if grains['nodename'] == 'dom0' %}
{% set gui_desktops = lock.get('gui_apps', {}).values() | map(attribute='desktop_file') | select | join(' ') %}
{% set items = 'qubes-run-terminal.desktop qubes-start.desktop ' ~ gui_desktops %}
{{ set_menu_items(cfg.agents.template.name, items) }}
{% for name in cfg.agents.get('qubes', []) %}
{{ set_menu_items(name, items) }}
"{{ name }}-sync-appmenus":
  cmd.run:
    - name: qvm-sync-appmenus {{ name }}
    - runas: user
    - onlyif: qvm-check --running {{ name }}
    - require:
      - qvm: {{ name }}-set-menu-items
{% endfor %}
{% endif %}
