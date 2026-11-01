{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Bind each agent AppVM's timezone and locale to its NetVM's VPN exit.

Runs in dom0. For every name in cfg.agents.qubes, read the live netvm and
copy cfg.agents.exits[netvm] into vm-config features. The template's boot
service reads those features after Qubes has applied dom0's zone.

anon-timezone stops dom0 from writing /qubes-timezone into the qube. Qubes
treats that feature as one-way from inside the VM; dom0 can still unset it.

A netvm that is not in cfg.agents.exits fails this state. Apply again after
changing an agent qube's netvm or after editing an exit's city:

  sudo qubesctl state.apply agents.exit

Halted qubes stay halted. A running qube keeps the new feature in QubesDB
immediately and uses it on the next start.
#}

{% from 'config.jinja' import cfg with context %}

{% if grains['nodename'] == 'dom0' %}
{% for name in cfg.agents.get('qubes', []) %}
{% set netvm = salt['cmd.run']('qvm-prefs ' ~ name ~ ' netvm').strip() %}
{% set exit = cfg.agents.get('exits', {}).get(netvm) %}
{% if not exit %}
"{{ name }}-exit-missing":
  cmd.run:
    - name: echo "{{ name }} netvm {{ netvm }} has no cfg.agents.exits entry" >&2; exit 1
{% else %}
"{{ name }}-anon-timezone":
  cmd.run:
    - name: qvm-features {{ name }} anon-timezone 1
    - unless: test "$(qvm-features {{ name }} anon-timezone)" = 1

"{{ name }}-exit-timezone":
  cmd.run:
    - name: qvm-features {{ name }} vm-config.timezone {{ exit.timezone }}
    - unless: test "$(qvm-features {{ name }} vm-config.timezone)" = "{{ exit.timezone }}"

"{{ name }}-exit-locale":
  cmd.run:
    - name: qvm-features {{ name }} vm-config.locale {{ exit.locale }}
    - unless: test "$(qvm-features {{ name }} vm-config.locale)" = "{{ exit.locale }}"
{% endif %}
{% endfor %}
{% endif %}
