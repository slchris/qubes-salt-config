{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Create RemoteVMs and wire them to the relay (dom0).

For each target in cfg.remotevm.targets this creates a qube of class RemoteVM
and sets the three RemoteVM properties that make it reachable through the relay:

  relayvm        -> the LocalVM that relays (cfg.remotevm.relay)
  transport_rpc  -> the RPC the relay uses to forward (cfg.remotevm.transport_rpc)
  remote_name    -> the qube's name on the remote host

A RemoteVM has no disk/memory and cannot be started — it is an addressing shell.
The QubesDB mapping /remote/<local_name> is written automatically by the core
`Relay` extension when the relay qube starts, so we do not manage QubesDB here.

Aligns with the official RemoteVM design; see the qubes-air project doc
docs/remotevm-alignment.md.
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set rv = cfg.remotevm -%}
{%- set relay = rv.get('relay', 'mgmt-jump') -%}
{%- set transport = rv.get('transport_rpc', 'qubesair.SSHProxy') -%}
{%- set targets = rv.get('targets', []) -%}

{% if grains['nodename'] == 'dom0' %}

{% for t in targets %}
{%- set name = t.local_name -%}
{%- set remote_name = t.get('remote_name', name) -%}

# Create the RemoteVM only if it does not already exist (idempotent).
"remotevm-create-{{ name }}":
  cmd.run:
    - name: qvm-create --class RemoteVM --label gray -- {{ name }}
    - unless: qvm-check --quiet -- {{ name }}

# Set the three RemoteVM properties. qvm-prefs is idempotent, so no unless.
"remotevm-prefs-relayvm-{{ name }}":
  cmd.run:
    - name: qvm-prefs -- {{ name }} relayvm {{ relay }}
    - require:
      - cmd: "remotevm-create-{{ name }}"

"remotevm-prefs-transport-{{ name }}":
  cmd.run:
    - name: qvm-prefs -- {{ name }} transport_rpc {{ transport }}
    - require:
      - cmd: "remotevm-create-{{ name }}"

"remotevm-prefs-remote-name-{{ name }}":
  cmd.run:
    - name: qvm-prefs -- {{ name }} remote_name {{ remote_name }}
    - require:
      - cmd: "remotevm-create-{{ name }}"

{% endfor %}

{% endif %}
