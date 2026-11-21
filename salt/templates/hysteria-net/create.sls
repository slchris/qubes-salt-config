{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Create the transparent Hysteria2 proxy gateway (tpl-hysteria-net and one
sys-<key> per cfg.hysteria_nets key).

sys-hysteria is a ProxyVM (provides-network) that sends every downstream TCP
connection through a Hysteria2 (QUIC) tunnel using a local SOCKS5 client plus
redsocks for transparent redirect. Hysteria2's QUIC transport keeps throughput
high over a long-RTT cross-border path where a WireGuard/BBR tunnel collapses
to a few hundred KB/s.

The server address, port, auth and TLS settings are a secret and are never
stored in Salt — they live in /rw/config/hysteria-net/client.yaml inside the
gateway.

Deploy order matters: apply install and configure BEFORE starting the gateway
or any qube that uses it as netvm. Until the template's fail-closed oneshot is
in the image, the gateway has no base firewall.
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
- label: purple
- audiovm: ""
- memory: 400
- maxmem: 800
- include_in_backups: True
features:
- set:
  - menu-items: "qubes-run-terminal.desktop qubes-start.desktop"
  - default-menu-items: "qubes-run-terminal.desktop qubes-start.desktop"
{%- endload %}
{{ load(defaults) }}

{% for key, net in cfg.hysteria_nets.items() %}
{% load_yaml as defaults -%}
name: sys-{{ key }}
force: True
require:
- qvm: tpl-{{ name }}
present:
- template: {{ net.get('template', 'tpl-' ~ name) }}
- label: {{ net.get('label', 'purple') }}
prefs:
- template: {{ net.get('template', 'tpl-' ~ name) }}
- label: {{ net.get('label', 'purple') }}
- netvm: {{ net.get('netvm', 'sys-firewall') }}
- audiovm: ""
- memory: {{ net.get('memory', 400) }}
- maxmem: {{ net.get('maxmem', 1600) }}
- provides-network: True
- autostart: False
- include_in_backups: True
features:
- enable:
  - servicevm
{%- endload %}
{{ load(defaults) }}
{% endfor %}
