# SPDX-License-Identifier: MIT
# Copyright 2026 Chris Su
#
# Install GPG packages in tpl-gpg (Debian)

{% if grains['nodename'] != 'dom0' %}

"gpg-update":
  pkg.uptodate:
    - refresh: True

"gpg-packages":
  pkg.installed:
    - require:
      - pkg: gpg-update
    - pkgs:
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
