# SPDX-License-Identifier: MIT
# Copyright 2026 Chris Su
#
# Development template packages installation (Debian)
# Includes: VS Code, Go, Python, Node.js, Wireshark, and common dev tools

{% from 'config.jinja' import cfg with context %}
{% if grains['nodename'] != 'dom0' %}

{% if cfg.mirror.get('enabled', False) %}
include:
  - mgmt.mirror.debian
{% endif %}

"tpl-dev-update":
  pkg.uptodate:
    - refresh: True
{% if cfg.mirror.get('enabled', False) %}
    - require:
      - cmd: mirror-debian-repoint
{% endif %}

# Common development tools
"tpl-dev-install-common":
  pkg.installed:
    - require:
      - pkg: tpl-dev-update
    - pkgs:
      # Base tools
      - qubes-core-agent-networking
      - qubes-core-agent-passwordless-root
      - vim
      - neovim
      - git
      - curl
      - wget
      - man-db
      - bash-completion
      - tmux
      - htop
      - tree
      - jq
      - ripgrep
      - fd-find
      # Build essentials
      - build-essential
      - cmake
      - autoconf
      - automake
      - pkg-config
      # Python
      - python3
      - python3-pip
      - python3-venv
      - python3-dev
      # Go
      - golang
      # Node.js
      - nodejs
      - npm
      # Network analysis
      - wireshark
      - tshark
      - tcpdump
      - nmap
      # Container tools
      - podman
      - buildah

# VS Code repository (Debian/apt). Kept on the official packages.microsoft.com:
# there is no reliable China apt mirror for it (Azure CN CDN is binary-only).
# It ships its own CDN; only this one repo isn't mirror-accelerated.
"tpl-dev-vscode-key":
  cmd.run:
    - name: |
        set -e
        tmp="$(mktemp)"
        wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > "$tmp"
        test -s "$tmp"
        install -m 0644 "$tmp" /usr/share/keyrings/packages.microsoft.gpg
        rm -f "$tmp"
    # test -s (non-empty), not -f: a prior failed wget leaves an empty file via
    # the `>` redirect, and -f would then skip forever with an unusable keyring.
    - unless: test -s /usr/share/keyrings/packages.microsoft.gpg

"tpl-dev-vscode-repo":
  file.managed:
    - name: /etc/apt/sources.list.d/vscode.list
    - contents: |
        deb [arch=amd64 signed-by=/usr/share/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main
    - require:
      - cmd: tpl-dev-vscode-key

"tpl-dev-apt-update":
  cmd.run:
    - name: apt-get update
    - require:
      - file: tpl-dev-vscode-repo

"tpl-dev-install-vscode":
  pkg.installed:
    - require:
      - cmd: tpl-dev-apt-update
    - pkgs:
      - code

{% endif %}
