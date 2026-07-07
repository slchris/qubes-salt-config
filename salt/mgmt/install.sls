# SPDX-License-Identifier: MIT
# Copyright 2026 Chris Su
#
# Install packages in tpl-mgmt for salt management

{% if grains['nodename'] != 'dom0' %}

"mgmt-update-packages":
  pkg.uptodate:
    - refresh: True

"mgmt-installed":
  pkg.installed:
    - require:
      - pkg: mgmt-update-packages
    - install_recommends: False
    - skip_suggestions: True
    - setopt: "install_weak_deps=False"
    - pkgs:
      - qubes-mgmt-salt-vm-connector
      - socat

{% endif %}