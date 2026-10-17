{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Verify the agent bundle in tpl-agents. Run after agents.deliver.

This is intentionally a hard check: a template that is missing an agent, or
whose launcher points at a missing version tree, should fail here rather than
at first use in a project qube. `--version` does not need network, and Claude
Code's DISABLE_UPDATES managed setting is checked explicitly.
#}

{% if grains['nodename'] != 'dom0' %}

"agents-verify":
  cmd.run:
    - name: |
        set -eu
        mkdir -p /tmp/agents-verify
        test -x /opt/agents-bundle/node/current/bin/node
        grep -q 'DISABLE_UPDATES' /etc/claude-code/managed-settings.json
        for c in claude codex opencode pi grok; do
          command -v "$c" >/dev/null
          printf '%s: ' "$c"
          timeout 20 "$c" --version
        done
    - runas: user
    - env:
      - HOME: /tmp/agents-verify
    - shell: /bin/bash

{% endif %}
