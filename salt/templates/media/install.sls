# SPDX-License-Identifier: MIT
# Copyright 2026 Chris Su
#
# Multimedia template packages installation (Debian)
# Includes: mpv, vlc, ffmpeg, and multimedia tools

{% if grains['nodename'] != 'dom0' %}

"tpl-media-update":
  pkg.uptodate:
    - refresh: True

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
