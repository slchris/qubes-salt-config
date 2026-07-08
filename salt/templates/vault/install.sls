# SPDX-License-Identifier: MIT
# Copyright 2026 Chris Su
#
# Install password management packages in tpl-vault (Debian)

{% from 'config.jinja' import cfg with context %}
{% if grains['nodename'] != 'dom0' %}

{% if cfg.mirror.get('enabled', False) %}
include:
  - mgmt.mirror.debian
{% endif %}

"vault-update":
  pkg.uptodate:
    - refresh: True
{% if cfg.mirror.get('enabled', False) %}
    - require:
      - cmd: mirror-debian-repoint
{% endif %}

"vault-packages":
  pkg.installed:
    - require:
      - pkg: vault-update
    - pkgs:
      # Update-proxy support so the (minimal-based) TEMPLATE can install
      # packages. Does NOT network the vault AppVM (netvm="" in create.sls
      # controls that); it only lets the template reach the Qubes update proxy.
      - qubes-core-agent-networking
      # KeePassXC
      - keepassxc
      # pass (standard unix password manager)
      - pass
      - pass-otp
      # Qt GUI for pass
      - qtpass
      # Password generator
      - pwgen
      # Clipboard utilities
      - xclip
      - xsel
      # GPG (for pass encryption)
      - gnupg
      - pinentry-gtk2

{% endif %}
