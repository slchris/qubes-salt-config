{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Install MCP-server / AI-application development tooling in tpl-mcp (Debian).

Provides the runtimes and package managers used to build MCP servers
(TypeScript and Python SDKs) and AI apps that call model APIs. The MCP/AI SDKs
themselves (@modelcontextprotocol/sdk, mcp, anthropic, openai) are per-project
dependencies installed with npm/uv inside each project, not system packages,
so they are intentionally not installed globally here.
#}

{% if grains['nodename'] != 'dom0' %}

"tpl-mcp-update":
  pkg.uptodate:
    - refresh: True

# Base tooling + Python. Node.js comes from NodeSource below for a current LTS.
"tpl-mcp-install-base":
  pkg.installed:
    - require:
      - pkg: tpl-mcp-update
    - pkgs:
      - qubes-core-agent-networking
      - ca-certificates
      - curl
      - wget
      - git
      - gnupg
      - vim
      - tmux
      - jq
      - ripgrep
      - build-essential
      - python3
      - python3-pip
      - python3-venv
      - pipx

# uv: fast Python package/venv manager, the ergonomic way to scaffold MCP
# Python servers (`uv init`, `uv add mcp`). Installed system-wide to /usr/local.
"tpl-mcp-install-uv":
  cmd.run:
    - name: |
        curl -LsSf https://astral.sh/uv/install.sh \
          | env UV_INSTALL_DIR=/usr/local/bin sh
    - require:
      - pkg: tpl-mcp-install-base
    - unless: test -x /usr/local/bin/uv

# Node.js LTS from NodeSource (Debian's nodejs is often too old for MCP SDK).
"tpl-mcp-nodesource-key":
  cmd.run:
    - name: |
        curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
          | gpg --dearmor > /usr/share/keyrings/nodesource.gpg
    - require:
      - pkg: tpl-mcp-install-base
    - unless: test -f /usr/share/keyrings/nodesource.gpg

"tpl-mcp-nodesource-repo":
  file.managed:
    - name: /etc/apt/sources.list.d/nodesource.list
    - mode: '0644'
    - contents: |
        deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main
    - require:
      - cmd: tpl-mcp-nodesource-key

"tpl-mcp-apt-update":
  cmd.run:
    - name: apt-get update
    - require:
      - file: tpl-mcp-nodesource-repo

"tpl-mcp-install-nodejs":
  pkg.installed:
    - require:
      - cmd: tpl-mcp-apt-update
    - pkgs:
      - nodejs

{% endif %}
