# SPDX-License-Identifier: MIT
# Copyright 2026 Chris Su
#
# IM (Instant Messaging) template packages installation (Debian)
# Includes: weechat, telegram-desktop, and messaging tools

{% from 'config.jinja' import cfg with context %}
{% if grains['nodename'] != 'dom0' %}

{% if cfg.mirror.get('enabled', False) %}
include:
  - mgmt.mirror.debian
{% endif %}

"tpl-im-update":
  pkg.uptodate:
    - refresh: True
{% if cfg.mirror.get('enabled', False) %}
    - require:
      - cmd: mirror-debian-repoint
{% endif %}

# IM packages from Debian repos. telegram-desktop is in Debian trixie's contrib
# component (the mirrored apt sources include contrib), so it installs from the
# mirror — no telegram.org download (which has no China mirror) needed.
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
      # Telegram (Debian contrib)
      - telegram-desktop

{% endif %}
