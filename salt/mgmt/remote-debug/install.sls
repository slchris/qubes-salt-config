{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Install openssh-server in the jump qube's TEMPLATE (runs in the template).

This is the clean place for the SSH server: installing it in the template means
it is present and shared by the jump AppVM and survives template updates.
configure.sls has an in-qube fallback, but prefer this.
#}

{% if grains['nodename'] != 'dom0' %}

"remote-debug-openssh-update":
  pkg.uptodate:
    - refresh: True

"remote-debug-openssh-server":
  pkg.installed:
    - require:
      - pkg: remote-debug-openssh-update
    - pkgs:
      - openssh-server

# Do not auto-start sshd template-wide; the jump AppVM starts it via rc.local.
"remote-debug-openssh-disabled-in-template":
  service.disabled:
    - name: ssh
    - require:
      - pkg: remote-debug-openssh-server

{% endif %}
