{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Create the per-project WireGuard gateway qubes (tpl-project-net, sys-project-net).

sys-project-net is a ProxyVM (provides-network) that carries ONE project's
traffic through a WireGuard tunnel — Mullvad or any provider/peer that hands
out a standard wg-quick conf. Attach the project's qubes with
`qvm-prefs <qube> netvm sys-project-net` (templates.ai does this in salt).

Need another isolated project network? Copy this whole unit directory to
salt/templates/<other>-net/ — every qube name in the .sls files derives from
the directory name via slsdotpath — then edit the five .top files in the
copy BY HAND (tops cannot use slsdotpath): BOTH the state paths
(templates.project-net.<state> -> templates.<other>-net.<state>) AND the
target qube names (tpl-project-net/sys-project-net in install.top,
configure.top, init.top). Missing the state paths silently re-applies THIS
unit instead of the copy.

IMPORTANT deploy order: apply install + configure (and drop wg0.conf in)
BEFORE starting any qube that uses this gateway as its netvm. Until
configure has run inside sys-project-net, the fail-closed firewall does not
exist yet and downstream traffic would take the default (clearnet) path.
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
- memory: 300
- maxmem: 600
- include_in_backups: True
features:
- set:
  - menu-items: "qubes-run-terminal.desktop qubes-start.desktop"
  - default-menu-items: "qubes-run-terminal.desktop qubes-start.desktop"
{%- endload %}
{{ load(defaults) }}

{% load_yaml as defaults -%}
name: sys-{{ name }}
force: True
require:
- qvm: tpl-{{ name }}
present:
- template: tpl-{{ name }}
- label: orange
prefs:
- template: tpl-{{ name }}
- label: orange
- netvm: sys-firewall
- audiovm: ""
- memory: 300
- maxmem: 600
- provides-network: True
- autostart: False
- include_in_backups: True
features:
- enable:
  - servicevm
{%- endload %}
{{ load(defaults) }}
