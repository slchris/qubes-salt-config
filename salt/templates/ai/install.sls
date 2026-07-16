{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Install the AI agent workbench in tpl-ai (Debian):

  - the same dev/runtime base as templates/mcp (git, python3+pip+venv, pipx,
    uv, Debian nodejs/npm) — agents and MCP servers are per-project deps;
  - the desktop bits Claude Desktop (Electron) needs on a minimal template:
    dbus-user-session, libsecret-1-0 + gnome-keyring (Chromium os_crypt
    credential store — without a Secret Service the login token falls back to
    the weaker basic store);
  - Claude Desktop itself from Anthropic's OFFICIAL Linux apt repo
    (downloads.claude.ai, Linux beta since 2026-06; package `claude-desktop`).

downloads.claude.ai is a FOREIGN apt source: no CN mirror, reached only via
the Qubes update-proxy (same situation that got VS Code dropped from
templates/dev). The claude-desktop states are therefore LEAF states — nothing
requires them, so if the host cannot reach the repo the rest of the template
still installs, and only those states fail. Retry later (e.g. once
sys-project-net gives the host a working path) with:

  sudo qubesctl --skip-dom0 --targets=tpl-ai state.apply templates.ai.install

or install the .deb manually — see README.md.
#}

{% from 'config.jinja' import cfg with context %}
{%- set m = cfg.get('mirror', {}) -%}
{% if grains['nodename'] != 'dom0' %}

{# Guard exactly like mgmt.mirror.debian declares its state: enabled AND a
   non-empty debian_baseurl — guarding on enabled alone would emit a require
   on `mirror-debian-repoint` that does not exist when the URL is blank. #}
{% if m.get('enabled', False) and m.get('debian_baseurl', '') %}
include:
  - mgmt.mirror.debian
{% endif %}

"tpl-ai-update":
  pkg.uptodate:
    - refresh: True
{% if m.get('enabled', False) and m.get('debian_baseurl', '') %}
    - require:
      - cmd: mirror-debian-repoint
{% endif %}

"tpl-ai-install-base":
  pkg.installed:
    - require:
      - pkg: tpl-ai-update
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
      # Desktop/session bits Claude Desktop needs on a minimal template
      - dbus-user-session
      - libsecret-1-0
      - gnome-keyring

# uv — same rationale and proxy/mirror handling as templates/mcp/install.sls:
# a template has netvm=none, pip must be pointed at the update-proxy.
{% set pip_index = m.get('pip_index', '') if m.get('enabled', False) else '' %}
{% set pip_index_arg = ('-i ' ~ pip_index) if pip_index else '' %}
"tpl-ai-install-uv":
  cmd.run:
    - name: |
        pip3 install --proxy http://127.0.0.1:8082 \
          --break-system-packages --prefix=/usr/local {{ pip_index_arg }} uv
    - require:
      - pkg: tpl-ai-install-base
    - unless: test -x /usr/local/bin/uv

# Node.js from Debian's own repo (mirrored) — NodeSource has no CN mirror.
"tpl-ai-install-nodejs":
  pkg.installed:
    - require:
      - pkg: tpl-ai-install-base
    - pkgs:
      - nodejs
      - npm

# --- Claude Desktop (official Linux beta apt repo) ---------------------------
# Leaf states: failure here must not take the rest of the template down.
# curl needs the update-proxy explicitly (only apt is preconfigured for it).
"claude-desktop-apt-keyring":
  cmd.run:
    - name: |
        set -e
        install -d -m 0755 /usr/share/keyrings
        curl -fsSL --proxy http://127.0.0.1:8082 \
          https://downloads.claude.ai/claude-desktop/key.asc \
          -o /usr/share/keyrings/claude-desktop-archive-keyring.asc
    - runas: root
    - unless: test -s /usr/share/keyrings/claude-desktop-archive-keyring.asc
    - require:
      - pkg: tpl-ai-install-base

"claude-desktop-apt-source":
  file.managed:
    - name: /etc/apt/sources.list.d/claude-desktop.list
    - mode: '0644'
    - user: root
    - group: root
    - contents: |
        # SPDX-License-Identifier: MIT — managed by templates.ai.install
        deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/claude-desktop-archive-keyring.asc] https://downloads.claude.ai/claude-desktop/apt/stable stable main
    - require:
      - cmd: "claude-desktop-apt-keyring"

"claude-desktop-apt-update":
  cmd.run:
    - name: apt-get update
    - runas: root
    - require:
      - file: "claude-desktop-apt-source"

# No in-app updater on Linux: the apt repo IS the update channel, so future
# `pkg.uptodate` runs against this template keep the app current.
"claude-desktop-package":
  pkg.installed:
    - pkgs:
      - claude-desktop
    - require:
      - cmd: "claude-desktop-apt-update"

{% endif %}
