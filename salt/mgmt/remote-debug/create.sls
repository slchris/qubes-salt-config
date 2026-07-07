{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Create the remote-debug jump qube (dom0).

A dedicated, networked AppVM that terminates SSH from your dev machine and
relays commands into dom0. Keep it dedicated — do not reuse a dev/build qube.
#}

{%- set rd = salt['pillar.get']('remote_debug', {}) -%}
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
    - flags:
      - net

"remote-debug-prefs-{{ qube }}":
  qvm.prefs:
    - name: {{ qube }}
    - netvm: {{ netvm }}
    - require:
      - qvm: "remote-debug-create-{{ qube }}"

{% endif %}
