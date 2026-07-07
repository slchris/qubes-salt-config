{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Create the remote-debug jump qube (dom0).

A dedicated, networked AppVM that terminates SSH from your dev machine and
relays commands into dom0. Keep it dedicated — do not reuse a dev/build qube.
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set rd = cfg.remote_debug -%}
{%- set qube = rd.get('qube', 'mgmt-jump') -%}
{%- set template = rd.get('template', 'debian-13-minimal') -%}
{%- set label = rd.get('label', 'red') -%}
{%- set netvm = rd.get('netvm', 'sys-firewall') -%}

{% if grains['nodename'] == 'dom0' %}

"remote-debug-create-{{ qube }}":
  qvm.present:
    - name: {{ qube }}
    - template: {{ template }}
    - label: {{ label }}

"remote-debug-prefs-{{ qube }}":
  qvm.prefs:
    - name: {{ qube }}
    - netvm: {{ netvm }}
    # mgmt-jump is a normal AppVM that CONSUMES network from sys-firewall.
    # It must NOT provide network — the old `net` create flag set
    # provides_network=True, which made Qubes treat it like a service qube and
    # left its own NIC (enX0) DOWN with no IP (root cause of the SSH timeout).
    - provides_network: False
    - require:
      - qvm: "remote-debug-create-{{ qube }}"

{% endif %}
