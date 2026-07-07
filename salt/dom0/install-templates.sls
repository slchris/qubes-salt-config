# SPDX-License-Identifier: MIT
# Copyright 2026 Chris Su
#
# Install required base templates in dom0
# This must be run first before any other states

{% if grains['nodename'] == 'dom0' %}

# Install fedora-42-minimal (for mgmt and vpn)
"install-fedora-42-minimal":
  cmd.run:
    - name: qubes-dom0-update --clean qubes-template-fedora-42-minimal
    - unless: qvm-check fedora-42-minimal

# Install debian-13-minimal (for most templates)
"install-debian-13-minimal":
  cmd.run:
    - name: qubes-dom0-update --clean qubes-template-debian-13-minimal
    - unless: qvm-check debian-13-minimal


{% endif %}
