{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Create the sys-tailscale gateway qube (runs IN dom0).

A dedicated ProxyVM (NetVM) that joins a self-hosted Headscale tailnet and gives
the rest of the machine mesh access:

    sys-net -> sys-firewall -> sys-tailscale -> AppVMs

It is a normal networked AppVM based on cfg.tailscale.template, with
`provides-network: True` so downstream qubes can set it as their netvm. tailscaled
itself is installed in the TEMPLATE (mgmt.tailscale.install) and its state is
persisted with bind-dirs by mgmt.tailscale.configure — nothing about the daemon
lives here; this state only creates and wires the qube.

Deploy (from dom0):
  sudo qubesctl top.enable mgmt.tailscale.create
  sudo qubesctl state.apply mgmt.tailscale.create
  sudo qubesctl top.disable mgmt.tailscale.create
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set ts = cfg.get('tailscale', {}) -%}
{%- set qube = ts.get('qube', 'sys-tailscale') -%}
{%- set template = ts.get('template', 'debian-13-minimal') -%}
{%- set label = ts.get('label', 'green') -%}
{%- set netvm = ts.get('netvm', 'sys-firewall') -%}
{%- set memory = ts.get('memory', 400) -%}
{%- set maxmem = ts.get('maxmem', 800) -%}

{% if grains['nodename'] == 'dom0' %}
{% if ts.get('enabled', False) %}

# Create the gateway qube if it does not exist. Idempotent via qvm.present.
"tailscale-qube":
  qvm.present:
    - name: {{ qube }}
    - template: {{ template }}
    - label: {{ label }}
    - mem: {{ memory }}

# Wire it as a NetVM gateway. Kept separate from present so re-applies enforce
# prefs even on an already-existing qube.
"tailscale-qube-prefs":
  qvm.prefs:
    - name: {{ qube }}
    - netvm: {{ netvm }}
    - provides-network: True
    - memory: {{ memory }}
    - maxmem: {{ maxmem }}
    - autostart: True
    - require:
      - qvm: "tailscale-qube"

{% else %}

"tailscale-create-disabled-note":
  test.show_notification:
    - text: |
        mgmt.tailscale.create: cfg.tailscale.enabled is False — not creating
        {{ qube }}. Set tailscale.enabled + login_server in config.jinja.

{% endif %}
{% endif %}
