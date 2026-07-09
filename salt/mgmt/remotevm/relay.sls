{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Configure the relay qube for RemoteVM transport (runs IN the relay qube).

Installs the qubesair.SSHProxy transport service that dom0 invokes to forward a
call to a RemoteVM over SSH, plus an ~/.ssh/config entry per target so the
service resolves each remote qube name to the correct SSH host.

The relay is a normal networked AppVM (by default the remote-debug jump qube).
It needs an SSH client and qrexec-client-vm (present in Qubes AppVMs). Install
openssh-client in the TEMPLATE for persistence; this state adds a fallback.

Deploy (from dom0):
  sudo qubesctl --skip-dom0 --targets=<relay> state.apply mgmt.remotevm.relay
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set rv = cfg.remotevm -%}
{%- set relay = rv.get('relay', 'mgmt-jump') -%}
{%- set targets = rv.get('targets', []) -%}

{% if grains['nodename'] != 'dom0' %}

# Fallback: ensure an SSH client exists (prefer installing in the template).
"remotevm-ensure-ssh-client":
  cmd.run:
    - name: |
        if [ ! -x /usr/bin/ssh ]; then
          apt-get update && apt-get install -y openssh-client
        fi
    - runas: root

# The transport RPC service dom0 calls to forward to a RemoteVM.
"remotevm-transport-service":
  file.managed:
    - name: /etc/qubes-rpc/qubesair.SSHProxy
    - source: salt://mgmt/remotevm/files/qubesair.SSHProxy
    - mode: '0755'
    - user: root
    - group: root

# One ~/.ssh/config Host entry per target so the transport resolves each remote
# qube name to its SSH host. Managed as a single block so re-runs stay clean.
"remotevm-ssh-config":
  file.managed:
    - name: /home/user/.ssh/config
    - user: user
    - group: user
    - mode: '0600'
    - makedirs: True
    - dir_mode: '0700'
    - contents: |
        # SPDX-License-Identifier: MIT — managed by mgmt.remotevm.relay
        # One entry per RemoteVM target: HostName is where the relay reaches the
        # remote qrexec-client-vm. Adjust User/IdentityFile/ProxyJump as needed.
        {%- for t in targets %}
        Host {{ t.get('remote_name', t.local_name) }}
            HostName {{ t.host }}
            StrictHostKeyChecking accept-new
        {%- endfor %}
    - require:
      - cmd: "remotevm-ensure-ssh-client"

{% endif %}
