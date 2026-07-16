{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Prepare the Remote-Relay (gRPC server) deployment bundle.

The Remote-Relay runs the gRPC server ON THE REMOTE HOST (e.g. a cloud VM). That
host is OUTSIDE local Qubes salt's control, so this state does NOT deploy the
server directly — it renders a self-contained BUNDLE on the relay qube that you
copy to the remote host and run there:

  <bundle_dir>/
    qubesair-relay-server.service   systemd unit
    server.env                      listen addr + cert paths
    qubesair.Ping                   qrexec reachability service
    install.sh                      places files, enables the service

You provide on the remote host: the server binary (cross-compiled linux/amd64
from the qubes-air Go backend) and the mTLS server cert/key + client CA.

Deploy the bundle (from dom0, targeting the relay qube):
  sudo qubesctl --skip-dom0 --targets=<relay> state.apply mgmt.remotevm.grpc-remote
then copy <bundle_dir> to the remote host and run ./install.sh there.
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set g = cfg.remotevm.get('grpc', {}) -%}
{%- set r = g.get('remote', {}) -%}
{%- set bundle = r.get('bundle_dir', '/home/user/qubesair-remote-bundle') -%}

{% if grains['nodename'] != 'dom0' %}
{% if g.get('enabled', False) %}

"grpc-remote-bundle-dir":
  file.directory:
    - name: {{ bundle }}
    - user: user
    - group: user
    - mode: '0700'
    - makedirs: True

# systemd unit for the remote host.
"grpc-remote-unit":
  file.managed:
    - name: {{ bundle }}/qubesair-relay-server.service
    - user: user
    - group: user
    - mode: '0644'
    - contents: |
        # SPDX-License-Identifier: MIT — Qubes Air Remote-Relay (gRPC server)
        [Unit]
        Description=Qubes Air gRPC Remote-Relay server (mTLS, inbound tunnel)
        After=network-online.target
        Wants=network-online.target

        [Service]
        Type=simple
        EnvironmentFile=/etc/qubesair/server.env
        ExecStart={{ r.get('server_bin', '/usr/local/bin/qubesair-relay-server') }} \
          -listen ${QA_LISTEN} -cert ${QA_CERT} -key ${QA_KEY} -ca ${QA_CA} -qrexec
        Restart=always
        RestartSec=2
        NoNewPrivileges=true
        PrivateTmp=true

        [Install]
        WantedBy=multi-user.target
    - require:
      - file: "grpc-remote-bundle-dir"

# Server env (listen + cert paths on the remote host).
"grpc-remote-env":
  file.managed:
    - name: {{ bundle }}/server.env
    - user: user
    - group: user
    - mode: '0600'
    - contents: |
        # SPDX-License-Identifier: MIT — installed to /etc/qubesair/server.env
        QA_LISTEN={{ r.get('listen', '0.0.0.0:8443') }}
        QA_CERT={{ r.get('cert_file', '/etc/qubesair/server.crt') }}
        QA_KEY={{ r.get('key_file', '/etc/qubesair/server.key') }}
        QA_CA={{ r.get('ca_file', '/etc/qubesair/ca.crt') }}
    - require:
      - file: "grpc-remote-bundle-dir"

# qubesair.Ping reachability service for the remote host's qrexec.
"grpc-remote-ping":
  file.managed:
    - name: {{ bundle }}/qubesair.Ping
    - source: salt://mgmt/remotevm/files/qubesair.Ping
    - user: user
    - group: user
    - mode: '0755'
    - require:
      - file: "grpc-remote-bundle-dir"

# install.sh: run ON THE REMOTE HOST to place files and enable the service.
"grpc-remote-install-script":
  file.managed:
    - name: {{ bundle }}/install.sh
    - user: user
    - group: user
    - mode: '0755'
    - contents: |
        #!/bin/bash
        # SPDX-License-Identifier: MIT
        # Run on the REMOTE HOST as root. Assumes the server binary and mTLS
        # cert/key/CA are already present (see paths in server.env).
        set -euo pipefail
        install -d -m 0755 /etc/qubesair
        install -m 0600 "$(dirname "$0")/server.env" /etc/qubesair/server.env
        install -m 0755 "$(dirname "$0")/qubesair.Ping" /etc/qubes-rpc/qubesair.Ping || \
          echo "note: /etc/qubes-rpc not present (only needed on a Qubes remote)"
        install -m 0644 "$(dirname "$0")/qubesair-relay-server.service" \
          /etc/systemd/system/qubesair-relay-server.service
        systemctl daemon-reload
        echo "Installed. Ensure the server binary and certs exist, then:"
        echo "  systemctl enable --now qubesair-relay-server"
    - require:
      - file: "grpc-remote-bundle-dir"

{% else %}

"grpc-remote-disabled-note":
  test.show_notification:
    - text: |
        mgmt.remotevm.grpc-remote: cfg.remotevm.grpc.enabled is False — nothing
        to render. Set remotevm.grpc.enabled + grpc.remote.* in config.jinja.

{% endif %}
{% endif %}
