{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Install the build toolchain in tpl-agent-build (Debian minimal).

The template deliberately does NOT install Node from Debian: Node 22 is
downloaded at a pinned version by build-agents.sh into the bundle, so the
runtime the agents execute against is the same one the lock records. Debian's
nodejs is only a fallback we do not use.

qubes-core-agent-networking is what lets the template use the Qubes update
proxy for apt; it does not give the template a netvm.
#}

{% from 'config.jinja' import cfg with context %}
{% if grains['nodename'] != 'dom0' %}

{% if cfg.mirror.get('enabled', False) %}
include:
  - mgmt.mirror.debian
{% endif %}

"tpl-agent-build-update":
  pkg.uptodate:
    - refresh: True
{% if cfg.mirror.get('enabled', False) %}
    - require:
      - cmd: mirror-debian-repoint
{% endif %}

"tpl-agent-build-packages":
  pkg.installed:
    - require:
      - pkg: tpl-agent-build-update
    - pkgs:
      - qubes-core-agent-networking
      - ca-certificates
      - curl
      - wget
      - git
      - jq
      - xz-utils
      - tar
      - gzip
      - python3
      - build-essential
      - coreutils
      - findutils
      - less
      - vim
      - tmux

{% endif %}
