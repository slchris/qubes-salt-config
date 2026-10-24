{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Configure a SEPARATE relay qube (default mgmt-jump) for the per-call gRPC
transport with a console-ISSUED client certificate (path b — see
qubes-air/docs/grpc-transport-design.md §0.5). Runs IN the relay qube.

Unlike the daemon model (mgmt.remotevm.grpc-relay), this relay holds no CA and
runs no long-lived tunnel. It:
  - runs relay-bootstrap to obtain a short-lived client cert from the console
    over qrexec (its private key never leaves this qube);
  - answers RemoteVM transport calls with the qubesair.GrpcProxy handler, which
    dials the target agent per-call via relay-call in provisioned mode.

Everything durable lives on /rw (survives the AppVM root-volume reset). The two
fixed locations that DO reset — /etc/qubes-rpc/<service> and /usr/local/bin — are
re-linked from /rw at every boot by a boot script rc.local runs, which also runs
relay-bootstrap so the certificate is refreshed on boot. A systemd timer renews
it during long uptimes.

Deploy (from dom0):
  sudo qubesctl --skip-dom0 --targets=<relay> state.apply mgmt.remotevm.grpc-csr-relay
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set rv = cfg.remotevm -%}
{%- set csr = rv.get('grpc', {}).get('csr', {}) -%}
{%- set relay_dir = csr.get('relay_dir', '/rw/config/qubesair-relay') -%}
{%- set runtime_dir = '/rw/config/qubesair-relay-runtime' -%}
{%- set bin_dir = runtime_dir ~ '/bin' -%}
{%- set sysd_dir = runtime_dir ~ '/systemd' -%}
{%- set console = csr.get('console_qube', 'qubesair-console') -%}

{% if grains['nodename'] != 'dom0' %}
{% if csr.get('enabled', False) %}
{% if not csr.get('relay_call_sha256') or not csr.get('relay_bootstrap_sha256') %}
"grpc-csr-relay-sha-required":
  test.fail_without_changes:
    - name: |
        cfg.remotevm.grpc.csr.relay_call_sha256 / relay_bootstrap_sha256 are
        empty. Publish the binaries and pin their digests before applying.
    - failhard: True
{% else %}

# The identity directory is USER-owned: the qrexec transport service runs as
# `user` (Qubes default), so relay-bootstrap runs as `user` and writes relay.key
# (0600) as `user`, and the service can read it. Depending on a policy `user=root`
# does not work — the RemoteVM-rewritten call did not honour it.
"grpc-csr-relay-dir":
  file.directory:
    - name: {{ relay_dir }}
    - user: user
    - group: user
    - mode: '0700'
    - makedirs: True

# --- binaries + handler, all on /rw (persistent) ----------------------------
# rc.local executes boot.sh as root: its ancestors must not be user-writable.
# Keep runtime code separate from relay_dir, where user owns its private key.
"grpc-csr-relay-runtime-dir":
  file.directory:
    - name: {{ runtime_dir }}
    - user: root
    - group: root
    - mode: '0755'
    - makedirs: True
    - require_in:
      - file: "grpc-csr-relay-call-bin"
      - file: "grpc-csr-relay-bootstrap-bin"
      - file: "grpc-csr-relay-handler"
      - file: "grpc-csr-relay-connecttcp"
      - file: "grpc-csr-relay-renew-service"
      - file: "grpc-csr-relay-renew-timer"
      - file: "grpc-csr-relay-refresh-endpoints"
      - file: "grpc-csr-relay-endpoints-service"
      - file: "grpc-csr-relay-endpoints-timer"
      - file: "grpc-csr-relay-boot-script"

"grpc-csr-relay-call-bin":
  file.managed:
    - name: {{ bin_dir }}/relay-call
    - source: {{ csr.relay_call_source }}
    - source_hash: sha256={{ csr.relay_call_sha256 }}
    - makedirs: True
    - dir_mode: '0755'
    - user: root
    - group: root
    - mode: '0755'

"grpc-csr-relay-bootstrap-bin":
  file.managed:
    - name: {{ bin_dir }}/relay-bootstrap
    - source: {{ csr.relay_bootstrap_source }}
    - source_hash: sha256={{ csr.relay_bootstrap_sha256 }}
    - makedirs: True
    - user: root
    - group: root
    - mode: '0755'

"grpc-csr-relay-handler":
  file.managed:
    - name: {{ bin_dir }}/qubesair.GrpcProxy
    - source: salt://mgmt/remotevm/files/qubesair.GrpcProxy
    - makedirs: True
    - user: root
    - group: root
    - mode: '0755'

# Raw TCP tunnel handler (GUI / any streaming TCP), invoked directly on the relay
# (not via the RemoteVM rewrite). socat is already present on the relay.
"grpc-csr-relay-connecttcp":
  file.managed:
    - name: {{ bin_dir }}/qubesair.ConnectTCP
    - source: salt://mgmt/remotevm/files/qubesair.ConnectTCP
    - makedirs: True
    - user: root
    - group: root
    - mode: '0755'

# Fixed Xpra Unix stream via the agent's mTLS channel. Policy grants are
# separate and empty by default; installing the handler grants no access.
"grpc-csr-relay-connectdesktop":
  file.managed:
    - name: {{ bin_dir }}/qubesair.ConnectDesktop
    - source: salt://mgmt/remotevm/files/qubesair.ConnectDesktop
    - makedirs: True
    - user: root
    - group: root
    - mode: '0755'

# --- renewal timer (units live on /rw, linked into place by boot.sh) ---------
"grpc-csr-relay-renew-service":
  file.managed:
    - name: {{ sysd_dir }}/qubesair-relay-renew.service
    - makedirs: True
    - mode: '0644'
    - user: root
    - group: root
    - contents: |
        # SPDX-License-Identifier: MIT — managed by mgmt.remotevm.grpc-csr-relay
        [Unit]
        Description=Qubes Air relay certificate renewal (CSR to console)
        After=qubes-qrexec-agent.service

        [Service]
        Type=oneshot
        User=user
        ExecStart={{ bin_dir }}/relay-bootstrap -console {{ console }} -dir {{ relay_dir }}

"grpc-csr-relay-renew-timer":
  file.managed:
    - name: {{ sysd_dir }}/qubesair-relay-renew.timer
    - makedirs: True
    - mode: '0644'
    - user: root
    - group: root
    - contents: |
        # SPDX-License-Identifier: MIT — managed by mgmt.remotevm.grpc-csr-relay
        [Unit]
        Description=Renew the Qubes Air relay certificate periodically

        [Timer]
        OnCalendar={{ csr.get('renew_on_calendar', '*-*-* 04,10,16,22:00:00') }}
        Persistent=true

        [Install]
        WantedBy=timers.target

# --- endpoint refresh: pull the qube->ip:port map from the console -----------
# The relay learns each RemoteVM's address from the console (control plane) and
# writes it into its OWN QubesDB, which the qubesair.GrpcProxy handler reads.
# Runs as `user`: qubesdb-write works unprivileged, and this touches no key.
"grpc-csr-relay-refresh-endpoints":
  file.managed:
    - name: {{ bin_dir }}/refresh-endpoints.py
    - makedirs: True
    - mode: '0755'
    - user: root
    - group: root
    - source: salt://mgmt/remotevm/files/refresh-endpoints.py.jinja
    - template: jinja
    - context:
        console: {{ console }}
        runtime_dir: {{ runtime_dir }}
    - require:
      - file: "grpc-csr-relay-endpoints-lock"

# A persistent inode in a root-owned directory: user may lock but not replace it.
"grpc-csr-relay-endpoints-lock":
  file.managed:
    - name: {{ runtime_dir }}/endpoints.lock
    - user: user
    - group: user
    - mode: '0600'
    - contents: ''
    - replace: False
    - require:
      - file: "grpc-csr-relay-runtime-dir"

"grpc-csr-relay-obsolete-refresh":
  file.absent:
    - name: {{ bin_dir }}/refresh-endpoints.sh

"grpc-csr-relay-endpoints-service":
  file.managed:
    - name: {{ sysd_dir }}/qubesair-relay-endpoints.service
    - makedirs: True
    - mode: '0644'
    - user: root
    - group: root
    - contents: |
        # SPDX-License-Identifier: MIT — managed by mgmt.remotevm.grpc-csr-relay
        [Unit]
        Description=Qubes Air relay endpoint map refresh (pull from console)
        After=qubes-qrexec-agent.service

        [Service]
        Type=oneshot
        User=user
        ExecStart={{ bin_dir }}/refresh-endpoints.py

"grpc-csr-relay-endpoints-timer":
  file.managed:
    - name: {{ sysd_dir }}/qubesair-relay-endpoints.timer
    - makedirs: True
    - mode: '0644'
    - user: root
    - group: root
    - contents: |
        # SPDX-License-Identifier: MIT — managed by mgmt.remotevm.grpc-csr-relay
        [Unit]
        Description=Refresh the Qubes Air relay endpoint map frequently

        [Timer]
        OnCalendar={{ csr.get('endpoints_on_calendar', '*:0/2') }}
        Persistent=true

        [Install]
        WantedBy=timers.target

# --- boot script: relink the reset paths, start the timer, refresh the cert --
# /usr/local/bin and /etc/qubes-rpc are on the root volume and reset on reboot,
# so they are symlinked back to the /rw copies at every boot. Running
# relay-bootstrap here means the relay always comes up with a fresh certificate.
"grpc-csr-relay-boot-script":
  file.managed:
    - name: {{ runtime_dir }}/boot.sh
    - makedirs: True
    - mode: '0755'
    - user: root
    - group: root
    - contents: |
        #!/bin/bash
        # SPDX-License-Identifier: MIT — managed by mgmt.remotevm.grpc-csr-relay
        set -u
        ln -sf {{ bin_dir }}/relay-call        /usr/local/bin/relay-call
        ln -sf {{ bin_dir }}/relay-bootstrap   /usr/local/bin/relay-bootstrap
        ln -sf {{ bin_dir }}/qubesair.GrpcProxy /etc/qubes-rpc/qubesair.GrpcProxy
        ln -sf {{ bin_dir }}/qubesair.ConnectTCP /etc/qubes-rpc/qubesair.ConnectTCP
        ln -sf {{ bin_dir }}/qubesair.ConnectDesktop /etc/qubes-rpc/qubesair.ConnectDesktop
        ln -sf {{ bin_dir }}/refresh-endpoints.py /etc/qubes-rpc/qubesair.ForgetEndpoint
        ln -sf {{ sysd_dir }}/qubesair-relay-renew.service     /etc/systemd/system/qubesair-relay-renew.service
        ln -sf {{ sysd_dir }}/qubesair-relay-renew.timer       /etc/systemd/system/qubesair-relay-renew.timer
        ln -sf {{ sysd_dir }}/qubesair-relay-endpoints.service /etc/systemd/system/qubesair-relay-endpoints.service
        ln -sf {{ sysd_dir }}/qubesair-relay-endpoints.timer   /etc/systemd/system/qubesair-relay-endpoints.timer
        systemctl daemon-reload || true
        systemctl start qubesair-relay-renew.timer     2>/dev/null || true
        systemctl start qubesair-relay-endpoints.timer 2>/dev/null || true
        # Obtain/refresh the client certificate AS user, so relay.key is owned by
        # the user the qrexec transport service runs as. Non-fatal: a transient
        # failure must not block the rest of boot; the timer retries.
        runuser -u user -- {{ bin_dir }}/relay-bootstrap -console {{ console }} -dir {{ relay_dir }} || \
          echo "qubesair relay: bootstrap deferred to timer" >&2
        # Pull the endpoint map now so a reboot does not wait for the timer.
        runuser -u user -- {{ bin_dir }}/refresh-endpoints.py || \
          echo "qubesair relay: endpoint refresh deferred to timer" >&2

# Ensure rc.local exists (with a shebang) WITHOUT clobbering any existing
# content: replace:False writes the contents only when the file is absent.
"grpc-csr-relay-rc-local-exists":
  file.managed:
    - name: /rw/config/rc.local
    - makedirs: True
    - mode: '0755'
    - user: root
    - group: root
    - replace: False
    - contents: |
        #!/bin/sh
        # /rw/config/rc.local — Qubes AppVM per-boot script.

# rc.local runs the boot script every boot. Managed as a block so any other
# rc.local content is preserved. (file.blockreplace takes neither create nor
# mode — existence/mode are handled by the state above.)
"grpc-csr-relay-rc-local":
  file.blockreplace:
    - name: /rw/config/rc.local
    - marker_start: "# >>> qubesair grpc-csr-relay >>>"
    - marker_end: "# <<< qubesair grpc-csr-relay <<<"
    - content: "{{ runtime_dir }}/boot.sh || true"
    - append_if_not_found: True
    - require:
      - file: "grpc-csr-relay-rc-local-exists"

# Wire everything for THIS boot too, so the relay works right after apply without
# waiting for a reboot.
"grpc-csr-relay-activate-now":
  cmd.run:
    - name: {{ runtime_dir }}/boot.sh
    - runas: root
    - require:
      - file: "grpc-csr-relay-call-bin"
      - file: "grpc-csr-relay-bootstrap-bin"
      - file: "grpc-csr-relay-handler"
      - file: "grpc-csr-relay-connecttcp"
      - file: "grpc-csr-relay-connectdesktop"
      - file: "grpc-csr-relay-renew-service"
      - file: "grpc-csr-relay-renew-timer"
      - file: "grpc-csr-relay-refresh-endpoints"
      - file: "grpc-csr-relay-endpoints-service"
      - file: "grpc-csr-relay-endpoints-timer"
      - file: "grpc-csr-relay-boot-script"

"grpc-csr-relay-ready":
  cmd.run:
    - name: |
        set -e
        test -s {{ relay_dir }}/relay.key
        openssl verify -purpose sslclient -CAfile {{ relay_dir }}/ca.crt {{ relay_dir }}/relay.crt
        openssl x509 -in {{ relay_dir }}/relay.crt -noout -checkend 60
        {{ bin_dir }}/refresh-endpoints.py
    - runas: user
    - require:
      - cmd: "grpc-csr-relay-activate-now"

{% endif %}
{% endif %}
{% endif %}
