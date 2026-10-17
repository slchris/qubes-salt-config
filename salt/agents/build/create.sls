{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Create the agent build qubes.

  tpl-agent-build  Debian base with the build toolchain; netvm is empty
                   (templates have no network bar the Qubes update proxy)
  agent-build      the only qube in this unit with a netvm. It downloads the
                   pinned Node tarball and npm packages, verifies every digest,
                   and writes a self-contained bundle. It holds no credentials
                   and is not backed up: a bundle is reproducible from the lock.

The build NetVM is cfg.agents.build.netvm. It defaults to sys-firewall so the
pipeline works before the Mullvad/AnyTLS gateways exist; point it at a
dedicated sys-build-net later, and keep it separate from project exits so a
compromised build qube cannot observe project traffic.

Changing netvm requires the qube to be stopped: qvm.prefs will fail on a
running AppVM. Stop agent-build before changing cfg.agents.build.netvm.
#}

{% from 'config.jinja' import cfg with context %}
{%- from "qvm/template.jinja" import load -%}
{% set b = cfg.agents.build %}

include:
  - agents.build.clone

{% load_yaml as defaults -%}
name: {{ b.template }}
force: True
require:
- sls: agents.build.clone
prefs:
- label: {{ b.label }}
- audiovm: ""
- vcpus: {{ b.vcpus }}
- memory: {{ b.memory }}
- maxmem: {{ b.maxmem }}
- include_in_backups: False
features:
- set:
  - menu-items: "qubes-run-terminal.desktop qubes-start.desktop"
  - default-menu-items: "qubes-run-terminal.desktop qubes-start.desktop"
{%- endload %}
{{ load(defaults) }}

{% load_yaml as defaults -%}
name: {{ b.qube }}
force: True
require:
- qvm: {{ b.template }}
present:
- template: {{ b.template }}
- label: {{ b.label }}
prefs:
- template: {{ b.template }}
- label: {{ b.label }}
- netvm: {{ b.netvm }}
- audiovm: ""
- vcpus: {{ b.vcpus }}
- memory: {{ b.memory }}
- maxmem: {{ b.maxmem }}
- include_in_backups: False
features:
- set:
  - menu-items: "qubes-run-terminal.desktop qubes-start.desktop"
  - default-menu-items: "qubes-run-terminal.desktop qubes-start.desktop"
{%- endload %}
{{ load(defaults) }}

{# The default 2G private volume cannot hold the Node tarball, the npm cache,
   four npm agent trees and the 113 MB Claude Code .deb at once. 20G leaves
   room for several bundles and lets old versions stay for rollback.

   qvm-volume can only grow a volume. The guard mirrors qubesair.create: it
   compares bytes so a re-apply is a no-op instead of a failing shrink. Stop
   the qube before applying this state if it is running; qvm-volume resize
   refuses to grow a volume that is in use. #}
"agent-build-private-size":
  cmd.run:
    - name: qvm-volume resize {{ b.qube }}:private {{ b.private_size }}
    - unless: |
        want=$(numfmt --from=si {{ b.private_size }})
        have=$(qvm-volume info {{ b.qube }}:private size 2>/dev/null | tr -d '[:space:]')
        case "$have" in ''|*[!0-9]*)
          have=$(qvm-volume info {{ b.qube }}:private 2>/dev/null | awk '$1 == "size" { print $2 }') ;;
        esac
        case "$have" in ''|*[!0-9]*) exit 1 ;; esac
        [ "$have" -ge "$want" ]
    - require:
      - qvm: {{ b.qube }}
