{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Create the console template and the console AppVM (runs IN dom0).

  tpl-qubesair      the dedicated template (packages come from qubesair.install)
  qubesair-console  the AppVM that actually runs the console

The AppVM deliberately has NO inbound sshd — that is the entire reason it exists
instead of reusing mgmt-jump, which does accept inbound SSH. Nothing here opens
an input path, and no openssh-server is installed in the template. Qubes AppVMs
default-deny inbound (an empty custom-input chain), so unlike mgmt.tailscale and
mgmt.remote-debug this module adds NO custom-input accept rule anywhere. Reach
the console over the tailnet (cfg.qubesair.netvm = sys-tailscale) and an SSH
port-forward from there, not by opening a port on this qube.

Deploy (from dom0):
  sudo qubesctl top.enable qubesair.create
  sudo qubesctl state.apply qubesair.create
  sudo qubesctl top.disable qubesair.create
#}

{%- from "qvm/template.jinja" import load -%}
{%- from 'config.jinja' import cfg with context -%}
{%- set qa = cfg.get('qubesair', {}) -%}
{%- set template = qa.get('template', 'tpl-qubesair') -%}
{%- set qube = qa.get('qube', 'qubesair-console') -%}
{%- set label = qa.get('label', 'orange') -%}
{%- set netvm = qa.get('netvm', 'sys-firewall') -%}
{%- set vcpus = qa.get('vcpus', 2) -%}
{%- set memory = qa.get('memory', 1000) -%}
{%- set maxmem = qa.get('maxmem', 2400) -%}
{%- set private_size = qa.get('private_size', '10G') -%}

{% if qa.get('enabled', False) %}

include:
  - {{ slsdotpath }}.clone

{# The template holds the toolchain but never runs terraform, so it stays small.
   The AppVM below is where terraform actually plans and gets the memory. #}
{% load_yaml as defaults -%}
name: {{ template }}
force: True
require:
- sls: {{ slsdotpath }}.clone
prefs:
- label: {{ label }}
- audiovm: ""
- vcpus: 2
- memory: 400
- maxmem: 2000
- include_in_backups: True
features:
- set:
  - menu-items: "qubes-run-terminal.desktop qubes-start.desktop"
  - default-menu-items: "qubes-run-terminal.desktop qubes-start.desktop"
{%- endload %}
{{ load(defaults) }}

{# The console AppVM.

   netvm comes from config (sys-tailscale by default) and carries an ORDERING
   DEPENDENCY: sys-tailscale must already exist or this qvm.prefs fails on a
   netvm that is not there. Deploy mgmt.tailscale first, or set
   cfg.qubesair.netvm to sys-firewall. Either way the netvm must reach
   10.31.0.0/24 — the console talks to the PVE API on the LAN, and it is also
   how the split-horizon resolver in qubesair.configure reaches 10.31.0.252.

   No autostart: this qube holds the PVE token and the agent CA key, so it comes
   up when someone means to use it rather than on every boot. Turn it on with
   `qvm-prefs {{ qube }} autostart True` once the console runs as a service.

   Memory is sized for terraform, not for the console: a plan across the fleet
   plus the bpg/proxmox provider needs considerably more than the 400MB the
   other AppVMs in config.jinja use, and the machine only has ~3.9G. #}
{% load_yaml as defaults -%}
name: {{ qube }}
force: True
require:
- qvm: {{ template }}
present:
- template: {{ template }}
- label: {{ label }}
prefs:
- template: {{ template }}
- label: {{ label }}
- netvm: {{ netvm }}
- audiovm: ""
- vcpus: {{ vcpus }}
- memory: {{ memory }}
- maxmem: {{ maxmem }}
- include_in_backups: True
features:
- set:
  - menu-items: "qubes-run-terminal.desktop"
  - default-menu-items: "qubes-run-terminal.desktop"
{%- endload %}
{{ load(defaults) }}

{# The default 2G private volume does not hold the terraform provider cache
   (~200MB), the .terraform directory, the SQLite database and the agent
   identity documents at once. terraform's failure mode when it runs out of
   space mid-apply is a half-written state file, i.e. a fleet whose real shape
   and recorded shape have diverged — much more expensive than the disk.

   qvm-volume can only GROW a volume, so the guard compares sizes and skips
   rather than attempting a shrink (which errors out and fails the run) when the
   volume is already at least the configured size. numfmt does the IEC parsing
   so "10G" here means the same thing it means to qvm-volume. #}
"qubesair-private-size":
  cmd.run:
    - name: qvm-volume resize {{ qube }}:private {{ private_size }}
    {#- `qvm-volume info VM:VOL <property>` prints a bare value, but older/other
        versions print the whole property table. Both are handled: an unparsable
        first form falls back to picking the size row out of the table. Without
        that, a table would make the numeric comparison error out, the guard
        would read as "not satisfied", and the resize would be attempted on
        every single apply — failing each time once the volume is already at
        size, because qvm-volume refuses to shrink. #}
    - unless: |
        want=$(numfmt --from=iec {{ private_size }})
        have=$(qvm-volume info {{ qube }}:private size 2>/dev/null | tr -d '[:space:]')
        case "$have" in ''|*[!0-9]*)
          have=$(qvm-volume info {{ qube }}:private 2>/dev/null | awk '$1 == "size" { print $2 }') ;;
        esac
        case "$have" in ''|*[!0-9]*) exit 1 ;; esac
        [ "$have" -ge "$want" ]
    - require:
      - qvm: {{ qube }}

{% else %}

"qubesair-create-disabled-note":
  test.show_notification:
    - text: |
        qubesair.create: cfg.qubesair.enabled is False — not creating
        {{ template }} / {{ qube }}. Set qubesair.enabled in salt/config.jinja.

{% endif %}
