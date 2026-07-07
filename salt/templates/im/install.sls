# SPDX-License-Identifier: MIT
# Copyright 2026 Chris Su
#
# IM (Instant Messaging) template packages installation (Debian)
# Includes: weechat, telegram-desktop, and messaging tools

{% if grains['nodename'] != 'dom0' %}

"tpl-im-update":
  pkg.uptodate:
    - refresh: True

# IM packages from Debian repos
"tpl-im-install-base":
  pkg.installed:
    - require:
      - pkg: tpl-im-update
    - pkgs:
      # Base tools
      - qubes-core-agent-networking
      # IRC client
      - weechat
      - weechat-plugins
      # Matrix client
      - nheko
      # XMPP client
      - profanity
      # Email client (optional)
      - neomutt

# Telegram - download from official site (flatpak or manual)
# Debian doesn't have telegram in official repos
"tpl-im-telegram-deps":
  pkg.installed:
    - require:
      - pkg: tpl-im-update
    - pkgs:
      - libxcb-xkb1
      - libxkbcommon-x11-0

# Install Telegram via download
"tpl-im-telegram-download":
  cmd.run:
    - name: |
        cd /tmp && \
        wget -q https://telegram.org/dl/desktop/linux -O telegram.tar.xz && \
        tar -xf telegram.tar.xz && \
        mv Telegram /opt/ && \
        ln -sf /opt/Telegram/Telegram /usr/local/bin/telegram-desktop && \
        rm telegram.tar.xz
    - unless: test -f /opt/Telegram/Telegram
    - require:
      - pkg: tpl-im-telegram-deps

{% endif %}
