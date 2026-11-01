{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Configure agent-build: deliver the lock and the two scripts into the build
qube's persistent home. Runs inside agent-build, not dom0.

The lock is rendered from agents/lock.yml to JSON so build-agents.sh can parse
it with jq without a YAML dependency. No secrets are involved: the lock only
contains public versions, URLs and digests.
#}

{% from 'config.jinja' import cfg with context %}
{% import_yaml 'agents/lock.yml' as lock %}
{% if grains['nodename'] != 'dom0' %}
{% set b = cfg.agents.build %}

"agent-build-workspace":
  file.directory:
    - name: {{ b.workspace }}
    - user: user
    - group: user
    - mode: '0755'
    - makedirs: True

"agent-build-bundle-dir":
  file.directory:
    - name: {{ b.bundle_dir }}
    - user: user
    - group: user
    - mode: '0755'
    - makedirs: True

"agent-build-lock":
  file.managed:
    - name: {{ b.workspace }}/lock.json
    - user: user
    - group: user
    - mode: '0644'
    - contents: |
        {{ lock | tojson }}
    - require:
      - file: agent-build-workspace

"agent-build-script":
  file.managed:
    - name: {{ b.workspace }}/build-agents.sh
    - source: salt://agents/files/build-agents.sh
    - user: user
    - group: user
    - mode: '0755'
    - require:
      - file: agent-build-workspace

"agent-build-installer":
  file.managed:
    - name: {{ b.workspace }}/install-agents.sh
    - source: salt://agents/files/install-agents.sh
    - user: user
    - group: user
    - mode: '0755'
    - require:
      - file: agent-build-workspace

{% endif %}
