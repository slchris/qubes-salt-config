# SPDX-License-Identifier: MIT
# Copyright 2026 Chris Su
#
# Development template packages installation (Debian)
# Includes: VS Code, Go, Python, Node.js, Wireshark, and common dev tools

{% if grains['nodename'] != 'dom0' %}

"tpl-dev-update":
  pkg.uptodate:
    - refresh: True

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

# VS Code repository (Debian/apt)
"tpl-dev-vscode-key":
  cmd.run:
    - name: |
        wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /usr/share/keyrings/packages.microsoft.gpg
    - unless: test -f /usr/share/keyrings/packages.microsoft.gpg

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
