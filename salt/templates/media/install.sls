# SPDX-License-Identifier: MIT
# Copyright 2026 Chris Su
#
# Multimedia template packages installation (Debian)
# Includes: mpv, vlc, ffmpeg, and multimedia tools

{% from 'config.jinja' import cfg with context %}
{% if grains['nodename'] != 'dom0' %}

{% if cfg.mirror.get('enabled', False) %}
include:
  - mgmt.mirror.debian
{% endif %}

"tpl-media-update":
  pkg.uptodate:
    - refresh: True
{% if cfg.mirror.get('enabled', False) %}
    - require:
      - cmd: mirror-debian-repoint
{% endif %}

# Multimedia packages
"tpl-media-install":
  pkg.installed:
    - require:
      - pkg: tpl-media-update
    - pkgs:
      # Base tools
      - qubes-core-agent-networking
      # Video players
      - mpv
      - vlc
      # Audio players
      - audacious
      # Media tools
      - ffmpeg
      - yt-dlp
      # Image viewers
      - feh
      - sxiv
      # Audio tools
      - pavucontrol
      - pulseaudio-utils
      # Codecs
      - gstreamer1.0-plugins-base
      - gstreamer1.0-plugins-good
      - gstreamer1.0-plugins-bad
      - gstreamer1.0-plugins-ugly
      - gstreamer1.0-libav

{% endif %}
