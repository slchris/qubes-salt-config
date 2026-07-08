# SPDX-License-Identifier: MIT
# Copyright 2026 Chris Su
#
# Tools/Office template packages installation (Debian)
# Includes: GIMP, LibreOffice, and productivity tools

{% from 'config.jinja' import cfg with context %}
{% if grains['nodename'] != 'dom0' %}

{% if cfg.mirror.get('enabled', False) %}
include:
  - mgmt.mirror.debian
{% endif %}

"tpl-tools-update":
  pkg.uptodate:
    - refresh: True
{% if cfg.mirror.get('enabled', False) %}
    - require:
      - cmd: mirror-debian-repoint
{% endif %}

# Office and productivity tools
"tpl-tools-install":
  pkg.installed:
    - require:
      - pkg: tpl-tools-update
    - pkgs:
      # Base tools
      - qubes-core-agent-networking
      # Office suite
      - libreoffice-writer
      - libreoffice-calc
      - libreoffice-impress
      - libreoffice-draw
      # Image editing
      - gimp
      - inkscape
      # PDF tools
      - evince
      - pdfarranger
      - qpdf
      # Note taking
      - xournalpp
      # Archive tools
      - p7zip-full
      - unrar-free
      - file-roller
      # Document tools
      - pandoc
      - texlive-base
      # Fonts
      - fonts-noto
      - fonts-noto-cjk
      - fonts-liberation
      # Calculator
      - qalculate-gtk

{% endif %}
