# SPDX-License-Identifier: MIT
# Copyright 2026 Chris Su
#
# Development template packages installation (Debian)
# Includes: Go, Python, Node.js, Wireshark, and common dev tools
# (VS Code intentionally excluded — see note at the bottom)

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

# NOTE: VS Code is intentionally NOT installed here. Its apt repo lives on
# packages.microsoft.com (no reliable China mirror), which is unreachable often
# enough from a China-network template that it kept failing the whole install.
# neovim (above) is the default editor; install VS Code / VSCodium manually if
# needed, e.g.:  wget -qO- https://packages.microsoft.com/keys/microsoft.asc ...

{% endif %}
