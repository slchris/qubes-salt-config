{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Client side of Split GPG 2 and Split SSH for a profile's project AppVM.

Runs in the AppVM. The gpg qube name comes from the cfg.profiles entry
whose project is this qube. Any other AppVM, including an agent test qube
that is only listed in cfg.agents.qubes, is left untouched.

The template packages come from agents.template.split, and the RPC policy
from templates.gpg.policy. Apply after those, then restart the AppVM so
split-gpg2-client replaces the local gpg-agent:

  sudo qubesctl --skip-dom0 --targets=slchris-project state.apply agents.split

Secret keys are not copied here. This state does not import a public key.
#}

{% from 'config.jinja' import cfg with context %}
{% set qube = grains['nodename'] %}
{% set found = namespace(name='', gpg='') %}
{% for name, profile in cfg.profiles.items() %}
{% if profile.project == qube %}
{% set found.name = name %}
{% set found.gpg = profile.gpg %}
{% endif %}
{% endfor %}

{% if found.name %}

"agents-split-gnupg-dir":
  file.directory:
    - name: /home/user/.gnupg
    - user: user
    - group: user
    - mode: '0700'
    - makedirs: True

"agents-split-config-dir":
  file.directory:
    - name: /home/user/.config
    - user: user
    - group: user
    - mode: '0755'
    - makedirs: True

"agents-split-ssh-dir":
  file.directory:
    - name: /home/user/.ssh
    - user: user
    - group: user
    - mode: '0700'
    - makedirs: True

"agents-split-gpg2-rc":
  file.managed:
    - name: /home/user/.config/split-gpg2-rc
    - user: user
    - group: user
    - mode: '0644'
    - contents: |
        # Sourced by /usr/share/split-gpg2/split-gpg2-client.
        SPLIT_GPG2_SERVER_DOMAIN={{ found.gpg }}
    - require:
      - file: agents-split-config-dir

# ssh reads this even when the shell is non-interactive, which is how
# Claude Code and git invoke it. The socket is created at boot below.
"agents-split-ssh-config":
  file.append:
    - name: /home/user/.ssh/config
    - text: |
        # BEGIN {{ found.name }} split-ssh
        IdentityAgent /home/user/.SSH_AGENT_gpg
        # END {{ found.name }} split-ssh
    - unless: grep -q 'BEGIN {{ found.name }} split-ssh' /home/user/.ssh/config
    - require:
      - file: agents-split-ssh-dir

"agents-split-ssh-config-mode":
  cmd.run:
    - name: chown user:user /home/user/.ssh/config && chmod 600 /home/user/.ssh/config
    - unless: test "$(stat -c '%a:%U:%G' /home/user/.ssh/config)" = 600:user:user
    - require:
      - file: agents-split-ssh-config

"agents-split-bashrc":
  file.append:
    - name: /home/user/.bashrc
    - text: |
        # BEGIN {{ found.name }} split-ssh
        export SSH_AUTH_SOCK="/home/user/.SSH_AGENT_gpg"
        # END {{ found.name }} split-ssh
    - unless: grep -q 'BEGIN {{ found.name }} split-ssh' /home/user/.bashrc

"agents-split-rc-local-present":
  cmd.run:
    - name: printf '%s\n' '#!/bin/sh' > /rw/config/rc.local && chmod 755 /rw/config/rc.local
    - unless: test -f /rw/config/rc.local

"agents-split-rc-local":
  file.append:
    - name: /rw/config/rc.local
    - require:
      - cmd: agents-split-rc-local-present
    - text: |
        # BEGIN {{ found.name }} split-ssh
        # systemd-run leaves the forwarder outside rc.local's cgroup, so it
        # stays up after this oneshot exits. The private key stays in {{ found.gpg }}.
        SOCK="/home/user/.SSH_AGENT_gpg"
        if ! systemctl is-active --quiet split-ssh-client.service; then
            rm -f "$SOCK"
            systemd-run --unit=split-ssh-client --collect --uid=user --gid=user \
                /usr/bin/socat "UNIX-LISTEN:${SOCK},fork,mode=600" \
                "EXEC:qrexec-client-vm {{ found.gpg }} qubes.SshAgent"
        fi
        # END {{ found.name }} split-ssh
    - unless: grep -q 'BEGIN {{ found.name }} split-ssh' /rw/config/rc.local

{% elif qube != 'dom0' %}

"agents-split-not-a-profile":
  test.succeed_without_changes:
    - name: {{ qube }} is not a profile project qube

{% endif %}
