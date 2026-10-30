{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Create the per-project WireGuard gateway qubes (tpl-project-net, sys-project-net).

sys-project-net is a ProxyVM (provides-network) that carries ONE project's
traffic through a WireGuard tunnel — Mullvad or any provider/peer that hands
out a standard wg-quick conf. Attach the project's qubes with
`qvm-prefs <qube> netvm sys-project-net`.

Need another isolated project network? Add a key to cfg.project_nets in
config.jinja. The key becomes sys-<key>; every gateway shares tpl-project-net
and the same fail-closed firewall states, and each one needs its own
/rw/config/wireguard/wg0.conf (a secret, never stored in Salt). "project-net"
preserves the original sys-project-net. The BWG-side peer, ingress subnet and
routing table pair live in the homelab repo.

IMPORTANT deploy order: apply install + configure (and drop wg0.conf in)
BEFORE starting any qube that uses this gateway as its netvm. Until
configure has run inside sys-project-net, the fail-closed firewall does not
exist yet and downstream traffic would take the default (clearnet) path.
#}

{% from 'config.jinja' import cfg with context %}
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
- memory: 300
- maxmem: 600
- include_in_backups: True
features:
- set:
  - menu-items: "qubes-run-terminal.desktop qubes-start.desktop"
  - default-menu-items: "qubes-run-terminal.desktop qubes-start.desktop"
{%- endload %}
{{ load(defaults) }}

{# One gateway per project_nets key. The key becomes sys-<key>;
   "project-net" keeps the original sys-project-net. All of them use the
   same tpl-project-net and the same per-qube firewall state. #}
{% for key, net in cfg.project_nets.items() %}
{% load_yaml as defaults -%}
name: sys-{{ key }}
force: True
require:
- qvm: tpl-{{ name }}
present:
- template: {{ net.get('template', 'tpl-' ~ name) }}
- label: {{ net.get('label', 'orange') }}
prefs:
- template: {{ net.get('template', 'tpl-' ~ name) }}
- label: {{ net.get('label', 'orange') }}
- netvm: {{ net.get('netvm', 'sys-firewall') }}
- audiovm: ""
- memory: {{ net.get('memory', 300) }}
- maxmem: {{ net.get('maxmem', 600) }}
- provides-network: True
- autostart: False
- include_in_backups: True
features:
- enable:
  - servicevm
{%- endload %}
{{ load(defaults) }}
{% endfor %}
