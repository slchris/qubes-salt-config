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
#
# The inbound-SSH nft rule MUST also live here, not only in
# qubes-firewall-user-script below. That script is executed by
# qubes-firewall.service, which carries
# `ConditionPathExists=/var/run/qubes-service/qubes-firewall` — a service only
# enabled on qubes that PROVIDE network (sys-net, sys-firewall). On a plain
# AppVM like this jump qube the unit never starts:
#   Condition: start condition unmet
#     └─ ConditionPathExists=/var/run/qubes-service/qubes-firewall was not met
# so the script never ran, custom-input stayed empty, and inbound SSH was
# dropped after EVERY reboot until the state was re-applied by hand (the
# `-now` cmd.run below is what made it look fixed each time).
# rc.local is run by qubes-misc-post.service on every AppVM boot, and measured
# on this qube it starts AFTER qubes-iptables.service has finished creating
# table ip qubes (06:03:26.602 vs 06:03:26.611), so custom-input already exists.
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
        # Open inbound SSH: Qubes AppVMs have `chain input` policy drop with
        # `jump custom-input`, and custom-input is empty by default.
        nft flush chain ip qubes custom-input 2>/dev/null || true
        nft add rule ip qubes custom-input tcp dport 22 ct state new,established,related counter accept
        # Leave a per-boot breadcrumb in /rw (survives reboot) so a failure can
        # be diagnosed from evidence instead of recollection. Compare its
        # timestamp against `uptime -s`: a line at boot time means this ran
        # automatically, no line means it did not run at all.
        printf '%s rc.local: custom-input accepts=%s\n' "$(date -Is)" \
          "$(nft list chain ip qubes custom-input 2>/dev/null | grep -c 'dport 22')" \
          >> /rw/config/remote-debug-boot.log 2>/dev/null || true

"remote-debug-start-sshd-now":
  cmd.run:
    - name: systemctl restart ssh || systemctl restart sshd
    - runas: root
    - require:
      - file: remote-debug-sshd-config
      - file: remote-debug-authorized-keys
      - cmd: remote-debug-ensure-sshd

# Same rule, also written to qubes-firewall-user-script. This is a NO-OP on a
# plain AppVM (see the rc.local block above — qubes-firewall.service never
# starts here, so nothing executes this file), and is kept only so the rule is
# still applied if this qube is ever given provides_network=True, where that
# service does run and rc.local ordering no longer applies. rc.local is the
# path that actually keeps inbound SSH working across reboots.
"remote-debug-inbound-fw":
  file.managed:
    - name: /rw/config/qubes-firewall-user-script
    - mode: '0755'
    - user: root
    - group: root
    - contents: |
        #!/bin/sh
        # remote-debug: accept inbound SSH. Qubes AppVMs have `chain input`
        # policy drop with `jump custom-input`; custom-input is empty by default,
        # so inbound SSH is dropped even though sshd listens and the port-forward
        # delivers the packet. Add the accept to custom-input (official method).
        # Flush our previous adds first so re-runs don't stack duplicates.
        nft flush chain ip qubes custom-input 2>/dev/null || true
        nft add rule ip qubes custom-input tcp dport 22 ct state new,established,related counter accept

"remote-debug-inbound-fw-now":
  cmd.run:
    - name: /rw/config/qubes-firewall-user-script
    - runas: root
    - require:
      - file: remote-debug-inbound-fw

{% endif %}
