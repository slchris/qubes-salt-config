# SPDX-License-Identifier: MIT
# Copyright 2026 Chris Su
#
# Install GPG packages in tpl-gpg (Debian)

{% from 'config.jinja' import cfg with context %}
{% if grains['nodename'] != 'dom0' %}

{% if cfg.mirror.get('enabled', False) %}
include:
  - mgmt.mirror.debian
{% endif %}

"gpg-update":
  pkg.uptodate:
    - refresh: True
{% if cfg.mirror.get('enabled', False) %}
    - require:
      - cmd: mirror-debian-repoint
{% endif %}

"gpg-packages":
  pkg.installed:
    - require:
      - pkg: gpg-update
    - pkgs:
      # Update-proxy / networking support so the (minimal-based) TEMPLATE can
      # install packages at all. This does NOT make the gpg AppVM networked —
      # that is controlled by netvm="" in create.sls; it only lets the template
      # reach the Qubes update proxy. Minimal templates lack this by default.
      - qubes-core-agent-networking
      # GPG core
      - gnupg
      - gnupg-agent
      - pinentry-gtk2
      # Smart card support
      - pcscd
      - libccid
      # Additional tools
      - hopenpgp-tools
      - paperkey
      # Sequoia PGP (modern implementation)
      - sq

# Enable pcscd for smart card support
"pcscd-service":
  service.enabled:
    - name: pcscd
    - require:
      - pkg: gpg-packages

{% endif %}
