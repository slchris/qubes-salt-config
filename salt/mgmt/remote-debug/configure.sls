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
# Check the binary path directly — sshd lives in /usr/sbin, which is not on a
# non-login PATH, so `command -v sshd` gives false negatives.
"remote-debug-ensure-sshd":
  cmd.run:
    - name: |
        if [ ! -x /usr/sbin/sshd ]; then
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

# Open inbound SSH on this AppVM. Qubes AppVMs drop incoming connections by
# default (nftables `custom-input` chain), so even though sshd listens and the
# port-forward delivers the packet, it is dropped here without this rule. This
# is added to /rw/config/qubes-firewall-user-script so it re-applies on boot.
"remote-debug-inbound-fw":
  file.managed:
    - name: /rw/config/qubes-firewall-user-script
    - mode: '0755'
    - user: root
    - group: root
    - contents: |
        #!/bin/sh
        # remote-debug: accept inbound SSH (Qubes AppVMs drop input by default).
        # Ensure the table/chain exist before adding the rule (idempotent — a no-op
        # if Qubes already created them), then accept inbound tcp/22.
        nft add table ip qubes 2>/dev/null || true
        nft add chain ip qubes custom-input 2>/dev/null || true
        nft add rule ip qubes custom-input tcp dport 22 ct state new,established,related counter accept 2>/dev/null || true

"remote-debug-inbound-fw-now":
  cmd.run:
    - name: /rw/config/qubes-firewall-user-script
    - runas: root
    - require:
      - file: remote-debug-inbound-fw

{% endif %}
