{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Configure the relay qube for RemoteVM transport (runs IN the relay qube).

Installs the qubesair.SSHProxy transport service that dom0 invokes to forward a
call to a RemoteVM over SSH, plus an ~/.ssh/config entry per target so the
service resolves each remote qube name to the correct SSH host.

The relay is a normal networked AppVM (by default the remote-debug jump qube).
It needs an SSH client and qrexec-client-vm (present in Qubes AppVMs). Install
the SSH client in the TEMPLATE for persistence; this state adds a fallback.

The transport service is persisted with bind-dirs (the AppVM's /etc is on the
root volume and is reset at every shutdown); ~/.ssh/config is on the private
volume and needs nothing.

Deploy (from dom0):
  sudo qubesctl --skip-dom0 --targets=<relay> state.apply mgmt.remotevm.relay
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set rv = cfg.remotevm -%}
{%- set relay = rv.get('relay', 'mgmt-jump') -%}
{%- set targets = rv.get('targets', []) -%}

{% if grains['nodename'] != 'dom0' %}

# Fallback: ensure an SSH client exists (prefer installing in the template —
# a package installed here lives on the root volume and is gone at the next
# start, so this only carries the current boot).
#
# Both package managers, because the relay template is not necessarily Debian:
# the qubes-air runbook uses a Fedora relay, where an apt-only fallback fails
# with "apt-get: not found" while reporting a state failure that reads like a
# network problem.
"remotevm-ensure-ssh-client":
  cmd.run:
    - name: |
        if [ ! -x /usr/bin/ssh ]; then
          if command -v apt-get >/dev/null 2>&1; then
            apt-get update && apt-get install -y openssh-client
          elif command -v dnf >/dev/null 2>&1; then
            dnf install -y openssh-clients
          else
            echo "no supported package manager; install an SSH client in the template" >&2
            exit 1
          fi
        fi
    - runas: root

# The transport RPC service dom0 calls to forward to a RemoteVM.
#
# Written to the bind-dirs SOURCE under /rw, not straight to /etc/qubes-rpc.
#
# An AppVM's /etc is on the root volume, which is discarded at every shutdown. A
# file written directly there works on the day it is deployed and is silently
# absent at the next start — the transport would disappear with no error, and the
# only symptom is a cross-machine call failing much later. bind-dirs.sh projects
# /rw/bind-dirs/<path> back over <path> during early boot, so the canonical copy
# has to live under /rw. Writing to /etc and *also* listing it in binds does not
# work either: bind-dirs seeds its /rw copy from whatever is at <path> the first
# time it sees the bind, and by the next boot the root volume has already been
# reset, so it seeds from the template — which has no such file.
"remotevm-transport-service":
  file.managed:
    - name: /rw/bind-dirs/etc/qubes-rpc/qubesair.SSHProxy
    - source: salt://mgmt/remotevm/files/qubesair.SSHProxy
    - makedirs: True
    - mode: '0755'
    - user: root
    - group: root

# Refuse to proceed if this qube uses custom-persist, because then the .conf
# below is never read and the transport would be lost at the next boot with
# nothing reporting a problem:
#
#   sources=( "/usr/lib/qubes-bind-dirs.d" "/etc/qubes-bind-dirs.d" )
#   if [ ! -f "/var/run/qubes-service/custom-persist" ]; then
#       sources+=( "/rw/config/qubes-bind-dirs.d" )
#   fi
#
# (bind-dirs.sh, qubes-core-agent 4.3.45-1+deb13u1.) With the service enabled the
# binds come from QubesDB instead, set from dom0 with
#   qvm-features <relay> custom-persist.qubesair file:root:root:0755:/etc/qubes-rpc/qubesair.SSHProxy
# Failing here is deliberate: a silently dropped transport is the failure mode
# this state exists to prevent.
"remotevm-transport-persist-mechanism":
  cmd.run:
    - name: |
        if [ -f /var/run/qubes-service/custom-persist ]; then
          echo "custom-persist is enabled on this qube: /rw/config/qubes-bind-dirs.d is ignored." >&2
          echo "Set the bind via qvm-features from dom0 instead — see the comment in mgmt/remotevm/relay.sls." >&2
          exit 1
        fi
    - runas: root

# bind-dirs: project the transport back into /etc/qubes-rpc on every boot.
"remotevm-transport-bind-dirs":
  file.managed:
    - name: /rw/config/qubes-bind-dirs.d/50_qubesair.conf
    - require:
      - cmd: "remotevm-transport-persist-mechanism"
    - makedirs: True
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        # Managed by mgmt.remotevm.relay
        binds+=( '/etc/qubes-rpc/qubesair.SSHProxy' )

# Make the transport real for THIS boot. The .conf above only takes effect at the
# next one — bind-dirs.sh runs during early boot, long before salt gets here — so
# without this the relay has no transport until it is restarted. mount --bind
# needs an existing target and the template ships none, so it is created empty
# first. `mountpoint -q ||` makes re-runs a no-op.
#
# No fallback is needed for the next boot: bind-dirs.sh creates a missing target
# itself when the /rw copy exists ("Create empty file or directory if path exists
# in /rw to allow to bind mount none existing files/dirs" — it touches the path
# and then binds). Verified by reading the shipped script on Qubes R4.3,
# qubes-core-agent 4.3.45-1+deb13u1. Anything installing the file a second time
# from rc.local would only be a second source for the same file.
"remotevm-transport-activate":
  cmd.run:
    - name: |
        set -e
        target=/etc/qubes-rpc/qubesair.SSHProxy
        mkdir -p /etc/qubes-rpc
        [ -e "$target" ] || : > "$target"
        chmod 0755 "$target"
        mountpoint -q "$target" \
          || mount --bind /rw/bind-dirs/etc/qubes-rpc/qubesair.SSHProxy "$target"
    - runas: root
    - require:
      - file: "remotevm-transport-service"
      - file: "remotevm-transport-bind-dirs"

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
