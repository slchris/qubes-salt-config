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

{% from 'config.jinja' import cfg with context %}
{% if grains['nodename'] != 'dom0' %}

{% if cfg.mirror.get('enabled', False) %}
include:
  - mgmt.mirror.debian
{% endif %}

"tpl-mcp-update":
  pkg.uptodate:
    - refresh: True
{% if cfg.mirror.get('enabled', False) %}
    - require:
      - cmd: mirror-debian-repoint
{% endif %}

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
# Python servers (`uv init`, `uv add mcp`). Installed via pip so it comes from the
# pip index — with mirror.enabled that's the TUNA PyPI mirror.
#
# A Qubes template has netvm=none: only apt/dnf reach the network, via the Qubes
# update-proxy at 127.0.0.1:8082 (qrexec tunnel). pip must be pointed at that same
# proxy explicitly, or it fails with "Temporary failure in name resolution".
{% set pip_index = cfg.mirror.get('pip_index', '') if cfg.mirror.get('enabled', False) else '' %}
{% set pip_index_arg = ('-i ' ~ pip_index) if pip_index else '' %}
"tpl-mcp-install-uv":
  cmd.run:
    - name: |
        pip3 install --proxy http://127.0.0.1:8082 \
          --break-system-packages --prefix=/usr/local {{ pip_index_arg }} uv
    - require:
      - pkg: tpl-mcp-install-base
    - unless: test -x /usr/local/bin/uv
    - unless: test -x /usr/local/bin/uv

# Node.js from Debian's own repo (via the mirror). NodeSource's external repo has
# no reliable China mirror; Debian 13 (trixie) ships a recent-enough Node for the
# MCP SDK, and it comes through the already-mirrored apt sources.
"tpl-mcp-install-nodejs":
  pkg.installed:
    - require:
      - pkg: tpl-mcp-install-base
    - pkgs:
      - nodejs
      - npm

{% endif %}
