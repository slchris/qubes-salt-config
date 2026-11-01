{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Deliver the newest agent bundle from agent-build to tpl-agents (dom0).

Prerequisites:
  - tpl-agents exists and agents.template.install has been applied
  - agent-build exists and agents.build.run has produced a bundle

The bundle crosses qrexec as a binary stream; it is verified against the
sha256 recorded by the build, then installed by the bundle's own install.sh.
Re-applying is cheap: the script exits immediately when the template already
holds the same bundle digest.
#}

{% from 'config.jinja' import cfg with context %}
{% set b = cfg.agents.build %}
{% set t = cfg.agents.template %}

{% if grains['nodename'] == 'dom0' %}

"agents-deliver-script":
  file.managed:
    - name: /tmp/deliver-agents-bundle.sh
    - source: salt://agents/files/deliver-agents-bundle.sh
    - mode: '0755'

"agents-deliver":
  cmd.run:
    - name: /tmp/deliver-agents-bundle.sh {{ b.qube }} {{ t.name }} {{ b.bundle_dir }}
    - require:
      - file: agents-deliver-script
    - onlyif: qvm-check {{ b.qube }}

{% endif %}
