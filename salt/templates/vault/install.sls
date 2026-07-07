# SPDX-License-Identifier: MIT
# Copyright 2026 Chris Su
#
# Install password management packages in tpl-vault (Debian)

{% if grains['nodename'] != 'dom0' %}

"vault-update":
  pkg.uptodate:
    - refresh: True

"vault-packages":
  pkg.installed:
    - require:
      - pkg: vault-update
    - pkgs:
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
