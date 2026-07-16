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
  - bind-dirs so the unit + config persist across the AppVM's root-volume reset.

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

# Persist config + unit across root-volume reset (AppVM /etc, /usr are reset).
"grpc-relay-bind-dirs":
  file.managed:
    - name: /rw/config/qubes-bind-dirs.d/50_qubesair_grpc.conf
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
"grpc-relay-unit":
  file.managed:
    - name: /etc/systemd/system/qubesair-relay-client.service
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

# Reload systemd so the new unit is visible. (Enable/start is left manual until
# the client binary is present — see the [TODO] in the header.)
"grpc-relay-daemon-reload":
  cmd.run:
    - name: systemctl daemon-reload
    - runas: root
    - onchanges:
      - file: "grpc-relay-unit"

{% else %}

"grpc-relay-disabled-note":
  test.show_notification:
    - text: |
        mgmt.remotevm.grpc-relay: cfg.remotevm.grpc.enabled is False — nothing to
        deploy. Set remotevm.grpc.enabled + remote_endpoint in config.jinja.

{% endif %}
{% endif %}
