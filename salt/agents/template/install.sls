{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Install the base development toolchain in tpl-agents (Debian minimal).

This state does NOT install Node or any coding agent: the agent bundle carries
a pinned Node runtime, the agent trees, and the pinned GUI application .debs.
Keeping those versions out of apt is what makes the bundle the unit of
versioning and rollback.

The template has no netvm; packages come through the Qubes update proxy.
qubes-core-agent-networking is installed for that proxy, not to give the
template a network.
#}

{% from 'config.jinja' import cfg with context %}
{% if grains['nodename'] != 'dom0' %}

{% if cfg.mirror.get('enabled', False) %}
include:
  - mgmt.mirror.debian
{% endif %}

"tpl-agents-update":
  pkg.uptodate:
    - refresh: True
{% if cfg.mirror.get('enabled', False) %}
    - require:
      - cmd: mirror-debian-repoint
{% endif %}

"tpl-agents-packages":
  pkg.installed:
    - require:
      - pkg: tpl-agents-update
    - pkgs:
      - qubes-core-agent-networking
      - qubes-core-agent-passwordless-root
      - ca-certificates
      - curl
      - wget
      - git
      - jq
      - xz-utils
      - tar
      - gzip
      - coreutils
      - findutils
      - python3
      - python3-venv
      - pipx
      - build-essential
      - ripgrep
      - openssh-client
      - gnupg
      - vim
      - tmux
      - less
      - procps
      - htop
      - tree
      - man-db
      - bash-completion
      # GUI applications (Chrome, VS Code, Claude Desktop) arrive as pinned
      # .debs in the bundle; these are the menu/desktop helpers, while the
      # applications' own library dependencies are resolved by
      # install-agents.sh's apt-get -f install.
      - xdg-utils
      - desktop-file-utils
      - fonts-liberation
      - dbus-x11

{% endif %}
