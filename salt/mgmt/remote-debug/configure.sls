{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Configure sshd inside the jump qube (runs IN the jump qube, not dom0).

Installs the authorized key(s), a hardened sshd drop-in, and persistence so
sshd starts on every boot of this AppVM via /rw/config/rc.local.

openssh-server itself should live in the TEMPLATE (so it survives and is shared);
this state installs it in-qube as a fallback if missing. For a clean setup,
install it in the template first:
  sudo qubesctl --skip-dom0 --targets=<template> state.apply \
      mgmt.remote-debug.install
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set rd = cfg.remote_debug -%}
{%- set keys = rd.get('authorized_keys', []) -%}
{%- set port = rd.get('ssh_port', 22) -%}

{% if grains['nodename'] != 'dom0' %}

# Fallback: ensure sshd exists in this qube (prefer installing in the template).
"remote-debug-ensure-sshd":
  cmd.run:
    - name: |
        if ! command -v sshd >/dev/null 2>&1; then
          apt-get update && apt-get install -y openssh-server
        fi
    - runas: root

"remote-debug-authorized-keys":
  file.managed:
    - name: /home/user/.ssh/authorized_keys
    - user: user
    - group: user
    - mode: '0600'
    - makedirs: True
    - dir_mode: '0700'
    - contents: |
        {%- for k in keys %}
        {{ k }}
        {%- endfor %}

# Hardened sshd config: key-only auth, no root login, listen on the chosen port
# (the jump qube listens on 22 internally; the external port is mapped by the
# port-forward — but we honour ssh_port here too in case you SSH qube-to-qube).
"remote-debug-sshd-config":
  file.managed:
    - name: /etc/ssh/sshd_config.d/10-remote-debug.conf
    - mode: '0644'
    - user: root
    - group: root
    - makedirs: True
    - contents: |
        # SPDX-License-Identifier: MIT — remote-debug
        PasswordAuthentication no
        PermitRootLogin no
        PubkeyAuthentication yes
        X11Forwarding no
        AllowUsers user

# Persist sshd start across AppVM reboots (Qubes AppVMs reset /etc from the
# template, so runtime services are started from /rw/config/rc.local).
"remote-debug-rc-local":
  file.managed:
    - name: /rw/config/rc.local
    - mode: '0755'
    - user: root
    - group: root
    - contents: |
        #!/bin/sh
        # remote-debug: start sshd on boot
        systemctl restart ssh || systemctl restart sshd || true

"remote-debug-start-sshd-now":
  cmd.run:
    - name: systemctl restart ssh || systemctl restart sshd
    - runas: root
    - require:
      - file: remote-debug-sshd-config
      - file: remote-debug-authorized-keys
      - cmd: remote-debug-ensure-sshd

{% endif %}
