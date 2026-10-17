{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Run the build in agent-build (dom0 state).

This runs npm install for every agent in the lock, so the build qube must be
the isolation boundary: no credentials, no project data, and (once available)
cfg.agents.build.netvm should point at a dedicated build NetVM, not a project
exit.

Prerequisite: agents.build.configure has been applied to agent-build, so
lock.json and the scripts exist. qvm-run starts the qube if it is halted.
#}

{% from 'config.jinja' import cfg with context %}
{% set b = cfg.agents.build %}

{% if grains['nodename'] == 'dom0' %}

"agents-build-run":
  cmd.run:
    - name: >-
        qvm-run --no-gui --pass-io -u user -- {{ b.qube }}
        'AGENT_BUILD_DIR={{ b.workspace }} AGENT_BUNDLE_DIR={{ b.bundle_dir }}
        {{ b.workspace }}/build-agents.sh'
    - onlyif: qvm-check {{ b.qube }}

{% endif %}
