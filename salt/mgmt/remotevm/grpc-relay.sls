{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Configure the relay qube for the gRPC bidi-stream transport (runs IN the relay
qube). This is the alternative to mgmt.remotevm.relay (SSHProxy); deploy one or
the other. See qubes-air/docs/grpc-transport-design.md.

Installs:
  - a config file (/rw/config/qubesair/relay.env) with the outbound endpoint,
    mTLS paths / vault cert names, keepalive and reconnect bounds;
  - a systemd unit (qubesair-relay-client.service) that runs the client daemon,
    which dials the remote Remote-Relay OUTBOUND and keeps one long-lived Tunnel;
  - bind-dirs so the unit persists across the AppVM's root-volume reset (the
    config already lives on /rw and needs no bind).

The relay is a normal networked AppVM (default: the remote-debug jump qube).
The client binary (cfg.remotevm.grpc.client_bin) is built and placed separately
(cross-compiled linux/amd64 from the qubes-air Go backend); this state wires the
service around it. [TODO] add a file.managed for the binary once CI publishes it.

Deploy (from dom0):
  sudo qubesctl --skip-dom0 --targets=<relay> state.apply mgmt.remotevm.grpc-relay
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set rv = cfg.remotevm -%}
{%- set g = rv.get('grpc', {}) -%}
{%- set relay = rv.get('relay', 'mgmt-jump') -%}

{% if grains['nodename'] != 'dom0' %}
{% if g.get('enabled', False) %}

# Refuse to proceed if this qube uses custom-persist: bind-dirs.sh then drops
# /rw/config/qubes-bind-dirs.d from its sources entirely and the unit would be
# lost at the next boot with nothing reporting a problem. (bind-dirs.sh,
# qubes-core-agent 4.3.45-1+deb13u1.) With the service enabled the binds come
# from QubesDB instead, set from dom0 with:
#   qvm-features <relay> custom-persist.qubesair-grpc \
#       file:root:root:0644:/etc/systemd/system/qubesair-relay-client.service
"grpc-relay-persist-mechanism":
  cmd.run:
    - name: |
        if [ -f /var/run/qubes-service/custom-persist ]; then
          echo "custom-persist is enabled on this qube: /rw/config/qubes-bind-dirs.d is ignored." >&2
          echo "Set the bind via qvm-features from dom0 instead — see the comment in mgmt/remotevm/grpc-relay.sls." >&2
          exit 1
        fi
    - runas: root

# Persist the unit across root-volume reset (AppVM /etc, /usr are reset).
# The config itself is already on /rw and needs no bind.
"grpc-relay-bind-dirs":
  file.managed:
    - name: /rw/config/qubes-bind-dirs.d/50_qubesair_grpc.conf
    - require:
      - cmd: "grpc-relay-persist-mechanism"
    - makedirs: True
    - mode: '0644'
    - contents: |
        # Managed by mgmt.remotevm.grpc-relay
        binds+=( '/etc/systemd/system/qubesair-relay-client.service' )

# Client config (endpoint, mTLS, keepalive/reconnect). No secrets here — certs
# come from the file paths or, preferably, vault-cloud via qrexec ask.
"grpc-relay-config":
  file.managed:
    - name: /rw/config/qubesair/relay.env
    - makedirs: True
    - dir_mode: '0700'
    - mode: '0600'
    - user: user
    - group: user
    - contents: |
        # SPDX-License-Identifier: MIT — managed by mgmt.remotevm.grpc-relay
        QUBES_AIR_TRANSPORT_ENABLED=true
        QUBES_AIR_TRANSPORT_REMOTE_ENDPOINT={{ g.get('remote_endpoint', '') }}
        QUBES_AIR_TRANSPORT_RELAY_NAME={{ relay }}
        QUBES_AIR_TRANSPORT_CERT_FILE={{ g.get('cert_file', '') }}
        QUBES_AIR_TRANSPORT_KEY_FILE={{ g.get('key_file', '') }}
        QUBES_AIR_TRANSPORT_CA_FILE={{ g.get('ca_file', '') }}
        QUBES_AIR_TRANSPORT_VAULT_CERTS={{ 'true' if g.get('vault_certs', False) else 'false' }}
        QUBES_AIR_TRANSPORT_VAULT_QUBE={{ g.get('vault_qube', 'vault-cloud') }}
        QUBES_AIR_TRANSPORT_VAULT_CERT_NAME={{ g.get('vault_cert_name', '') }}
        QUBES_AIR_TRANSPORT_VAULT_KEY_NAME={{ g.get('vault_key_name', '') }}
        QUBES_AIR_TRANSPORT_VAULT_CA_NAME={{ g.get('vault_ca_name', '') }}
        QUBES_AIR_TRANSPORT_REVERSE_LOCAL_TARGET={{ g.get('reverse_local_target', 'vault-cloud') }}
        QUBES_AIR_TRANSPORT_KEEPALIVE_SECONDS={{ g.get('keepalive_seconds', 20) }}
        QUBES_AIR_TRANSPORT_RECONNECT_MIN_SECONDS={{ g.get('reconnect_min_seconds', 1) }}
        QUBES_AIR_TRANSPORT_RECONNECT_MAX_SECONDS={{ g.get('reconnect_max_seconds', 30) }}

# systemd unit: run the outbound gRPC relay client daemon.
#
# Written to the bind-dirs SOURCE under /rw, not straight to /etc/systemd/system.
# Listing a path in binds while writing the file to the path itself does not
# survive: bind-dirs seeds its /rw copy from whatever is at <path> the first time
# it sees the bind, and by then the root volume has been reset, so it seeds from
# the template — which has no such unit, and the unit is gone.
"grpc-relay-unit":
  file.managed:
    - name: /rw/bind-dirs/etc/systemd/system/qubesair-relay-client.service
    - makedirs: True
    - mode: '0644'
    - user: root
    - group: root
    - contents: |
        # SPDX-License-Identifier: MIT — managed by mgmt.remotevm.grpc-relay
        [Unit]
        Description=Qubes Air gRPC relay client (outbound tunnel to Remote-Relay)
        After=qubes-qrexec-agent.service network-online.target
        Wants=network-online.target

        [Service]
        Type=simple
        EnvironmentFile=/rw/config/qubesair/relay.env
        ExecStart={{ g.get('client_bin', '/usr/local/bin/qubesair-relay-client') }}
        Restart=always
        RestartSec=2
        # Hardening: no new privileges, private tmp.
        NoNewPrivileges=true
        PrivateTmp=true

        [Install]
        WantedBy=multi-user.target
    - require:
      - file: "grpc-relay-config"

# Make the unit real for THIS boot, then reload so systemd sees it. The .conf
# above only takes effect at the next boot — bind-dirs.sh runs during early boot,
# long before salt gets here. mount --bind needs an existing target and the
# template ships none, so it is created empty first; `mountpoint -q ||` makes
# re-runs a no-op.
#
# No fallback is needed for the next boot: bind-dirs.sh creates a missing target
# itself when the /rw copy exists ("Create empty file or directory if path exists
# in /rw to allow to bind mount none existing files/dirs"). Verified by reading
# the shipped script on Qubes R4.3, qubes-core-agent 4.3.45-1+deb13u1.
#
# (Enable/start is left manual until the client binary is present — see the
# [TODO] in the header. When that happens, note that `systemctl enable` will NOT
# stick: it writes a symlink under /etc/systemd/system/multi-user.target.wants/,
# which is on the root volume and is discarded with it, leaving `is-enabled`
# reporting "enabled" on a boot where the service never started. Start it from
# /rw/config/rc.local instead, the way this repo starts its other AppVM units.)
"grpc-relay-unit-activate":
  cmd.run:
    - name: |
        set -e
        target=/etc/systemd/system/qubesair-relay-client.service
        mkdir -p /etc/systemd/system
        [ -e "$target" ] || : > "$target"
        chmod 0644 "$target"
        mountpoint -q "$target" \
          || mount --bind /rw/bind-dirs/etc/systemd/system/qubesair-relay-client.service "$target"
        systemctl daemon-reload
    - runas: root
    - require:
      - file: "grpc-relay-unit"
      - file: "grpc-relay-bind-dirs"

{% else %}

"grpc-relay-disabled-note":
  test.show_notification:
    - text: |
        mgmt.remotevm.grpc-relay: cfg.remotevm.grpc.enabled is False — nothing to
        deploy. Set remotevm.grpc.enabled + remote_endpoint in config.jinja.

{% endif %}
{% endif %}
