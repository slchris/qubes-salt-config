{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Configure the Qubes Air console service INSIDE its AppVM (runs IN the qube, not
dom0). Companion to the qubesair clone/install/create states, which build the
template and the qube; this state wires the service that runs in it.

Installs:
  - the console binary into cfg.qubesair.data_dir (see "Why /rw" below);
  - non-secret configuration at {data_dir}/console.env;
  - a generate-once secret file at {data_dir}/secrets.env (0600), the location
    config.jinja's own "qubesair secrets" note specifies;
  - a preflight script that refuses to start a misconfigured console, so a
    broken deployment lands in `failed` instead of serving happily with an
    encryption key that is published in the source repository;
  - a systemd unit, persisted across the AppVM root-volume reset via bind-dirs
    and started every boot from /rw/config/rc.local.

Why /rw for everything, including the binary
--------------------------------------------
An AppVM's root volume is discarded on every shutdown and re-derived from the
template. Anything this state writes to /usr, /etc or /var exists only until the
next reboot. So the binary, the database, the agent identity directory and the
terraform root all live under cfg.qubesair.data_dir, which is on /rw.

Worth stating because the obvious placement is wrong in a way that tests clean:
install to /usr/local/bin and the console runs perfectly until the first reboot,
after which the unit fails with "No such file or directory" and nothing explains
why it used to work. (cfg.qubesair.terraform_binary IS under /usr/local/bin, and
that is correct — the qubesair install state puts terraform in the TEMPLATE, so
it is re-derived on every boot rather than lost.)

Keeping the console binary out of the template is also what makes upgrading it a
file copy plus a service restart, instead of a template rebuild and a reboot of
every qube built from it.

What this state deliberately does NOT do
----------------------------------------
It never handles the Proxmox credential. The console reads cluster credentials
from its own ENCRYPTED credential store (console/internal/service/tfcreds.go:
the zone's proxmox.credential_id is looked up, decrypted with the keyring, and
injected into terraform's subprocess environment). A PROXMOX_VE_* variable in
this unit's environment would not be used for zone-scoped work at all — it would
simply be a second, plaintext copy of the secret in a salt-managed file, one
`git add -A` away from being published. The operator POSTs it once to
/api/v1/credentials; the notification at the end of a successful run says how.

Deploy (from dom0), after the console qube exists and is running:
  sudo qubesctl --skip-dom0 --targets=<cfg.qubesair.qube> state.apply qubesair.console
#}

{%- from 'config.jinja' import cfg with context -%}

{#- config.jinja is owned by the qubesair template/create states; read through
    .get() so a missing block yields the actionable notification at the bottom
    rather than a jinja traceback that names no key. -#}
{%- set qa = cfg.get('qubesair', {}) -%}

{%- set svc_user = qa.get('service_user', 'user') -%}
{%- set data_dir = qa.get('data_dir', '/rw/config/qubesair') -%}
{%- set tfrc = qa.get('terraform_cli_config', '/etc/terraform/cli.tfrc') -%}

{#- cfg.qubesair.listen is a single "host:port" string. rsplit on the LAST colon
    so a bare IPv6 literal does not lose its tail; a value with no colon at all
    falls back to the console's own default port rather than rendering an empty
    QUBES_AIR_PORT, which config.go would silently ignore. -#}
{%- set listen = qa.get('listen', '127.0.0.1:8080') -%}
{%- set listen_parts = listen.rsplit(':', 1) -%}
{%- set listen_host = listen_parts[0] -%}
{%- set listen_port = listen_parts[1] if listen_parts | length > 1 else '8080' -%}

{%- set db_path = qa.get('database_dsn', data_dir ~ '/qubes-air.db') -%}
{%- set db_dir = db_path.rsplit('/', 1)[0] -%}
{%- set identity_dir = qa.get('agent_identity_dir', data_dir ~ '/agent-identity') -%}
{%- set tf_dir = qa.get('terraform_dir', data_dir ~ '/terraform') -%}
{%- set tf_bin = qa.get('terraform_binary', 'terraform') -%}
{%- set var_file = qa.get('terraform_var_file', '') -%}
{%- set gen_var_file = qa.get('terraform_generated_var_file', 'generated/qubes.tfvars.json') -%}

{%- set bin_dir = data_dir ~ '/bin' -%}
{%- set bin_path = bin_dir ~ '/qubes-air-console' -%}
{%- set home_dir = data_dir ~ '/home' -%}
{%- set env_file = data_dir ~ '/console.env' -%}
{%- set secret_file = data_dir ~ '/secrets.env' -%}
{%- set preflight = data_dir ~ '/console-preflight.sh' -%}

{%- set orch = qa.get('orchestrator_enabled', False) -%}
{%- set cors = qa.get('cors_origins', []) -%}
{%- if not cors -%}
{%- set cors = ['http://' ~ listen] -%}
{%- endif -%}

{#- The console binary has no key in config.jinja yet: it is the one payload
    this state delivers that is neither a package nor a template artifact. -#}
{%- set bin_source = qa.get('console_binary_source', 'salt://qubesair/files/qubes-air-console') -%}
{%- set bin_sha = qa.get('console_binary_sha256', '') -%}

{#- The built frontend, shipped as a tarball of the vite dist/. Both keys must
    be set for the UI to be delivered; leaving them empty leaves the console
    serving its API and nothing else, which is a working console without a page
    rather than a broken one. -#}
{%- set web_source = qa.get('console_web_source', '') -%}
{%- set web_sha = qa.get('console_web_sha256', '') -%}
{%- set web_root = data_dir ~ '/web' -%}

{% if grains['nodename'] != 'dom0' %}
{% if qa.get('enabled', False) %}

{#- There is no CI publishing the console binary, so the digest is the ONLY
    thing distinguishing the reviewed build from whatever happens to sit at that
    path. Refuse to render a service around an unverified binary rather than
    shipping a state that reads as complete. -#}
{% if not bin_sha %}

"qubesair-console-binary-sha-required":
  test.fail_without_changes:
    - name: |
        cfg.qubesair.console_binary_sha256 is not set, and it has no default.

        Unlike terraform (fetched from a release URL by the qubesair install
        state), the console binary is built from the qubes-air Go source. Nothing
        publishes it, so it is cross-compiled by hand into this repo's salt tree
        and pinned by digest — otherwise "the console is deployed" says nothing
        about WHAT is deployed.

        On your workstation, in the qubes-air repo:

          docker run --rm --platform linux/amd64 -v "$PWD":/src \
              -w /src/console/backend golang:1.25 \
              sh -c 'CGO_ENABLED=1 GOOS=linux GOARCH=amd64 go build \
                  -trimpath -ldflags="-s -w" -o /src/dist/qubes-air-console ./cmd/server'
          shasum -a 256 dist/qubes-air-console

        Three parts of that are load-bearing:
          - CGO_ENABLED=1: the console uses mattn/go-sqlite3, a cgo package.
            CGO_ENABLED=0 compiles cleanly and produces a binary that fails at
            runtime with 'unknown driver "sqlite3"' — a clean build and a
            console that cannot open its own database.
          - --platform linux/amd64: on an Apple Silicon Mac the golang image is
            arm64 and a cgo build for GOARCH=amd64 needs an x86-64 cross
            toolchain it does not ship. Emulating amd64 makes it native inside
            the container.
          - golang:1.25: console/backend/go.mod requires go >= 1.25.0.

        Publish it to the artifact store (same login + read-back pattern as
        scripts/publish-agent-deb.sh), then add BOTH keys to the qubesair block
        in salt/config.jinja:

          "console_binary_source": "http://10.31.0.2/local/qubes-air-tools/qubes-air-console",
          "console_binary_sha256": "<the digest printed above>",

        and re-run scripts/setup.sh before applying this state again.
        Staging the binary at salt://qubesair/files/qubes-air-console still
        works if you prefer — see salt/qubesair/files/README.md.
    - failhard: True

{% else %}

# --- 1. Persistent directories ----------------------------------------------
# Modes are part of the design, not incidental:
#   agent-identity/  0700 — rendered cloud-init documents containing agent
#                    PRIVATE KEYS. The console creates it 0700 itself
#                    (service/cloudinit.go), but it is declared here too so the
#                    mode is reviewable in the state and stays correct if the Go
#                    side ever changes.
#   data_dir         0700 — the SQLite database sits directly in it and holds the
#                    CA private key and the Proxmox credential as ciphertext.
#                    Ciphertext is not public data; it is exactly what an offline
#                    attack needs.
"qubesair-console-data-dir":
  file.directory:
    - name: {{ data_dir }}
    - user: {{ svc_user }}
    - group: {{ svc_user }}
    - mode: '0700'
    - makedirs: True

"qubesair-console-bin-dir":
  file.directory:
    - name: {{ bin_dir }}
    - user: root
    - group: root
    - mode: '0755'
    - require:
      - file: "qubesair-console-data-dir"

{% if db_dir != data_dir %}
"qubesair-console-db-dir":
  file.directory:
    - name: {{ db_dir }}
    - user: {{ svc_user }}
    - group: {{ svc_user }}
    - mode: '0700'
    - require:
      - file: "qubesair-console-data-dir"
{% endif %}

"qubesair-console-identity-dir":
  file.directory:
    - name: {{ identity_dir }}
    - user: {{ svc_user }}
    - group: {{ svc_user }}
    - mode: '0700'
    - makedirs: True
    - require:
      - file: "qubesair-console-data-dir"

"qubesair-console-terraform-dir":
  file.directory:
    - name: {{ tf_dir }}
    - user: {{ svc_user }}
    - group: {{ svc_user }}
    - mode: '0750'
    - makedirs: True
    - require:
      - file: "qubesair-console-data-dir"

# HOME for the service. terraform writes a plugin cache and CLI state under
# $HOME; ProtectHome=yes in the unit hides the real /home/user, so HOME points
# here instead. Without it terraform falls back to an absent or unwritable home
# and `init` fails in a way that reads as a network problem.
"qubesair-console-home-dir":
  file.directory:
    - name: {{ home_dir }}
    - user: {{ svc_user }}
    - group: {{ svc_user }}
    - mode: '0700'
    - require:
      - file: "qubesair-console-data-dir"

# --- 2. The console binary ---------------------------------------------------
# It arrives from this repo's salt tree over the qrexec channel qubesctl already
# uses — no download, no artifact server. The operator cross-compiles it (recipe
# in the failure message above), drops it at
# salt/qubesair/files/qubes-air-console, and runs scripts/setup.sh.
#
# source_hash makes salt verify the digest before installing and fail the run on
# a mismatch, so "the right binary is deployed" is enforced rather than assumed.
# The file is NOT committed — it is a ~30MB build artifact — so a fresh clone
# rebuilds it, and the digest in config.jinja is what proves the rebuild matches
# what was reviewed.
#
# root-owned so a bug in the console cannot rewrite the binary it is executing.
# Note the honest limit of that: data_dir must be writable by the service (the
# database lives in it), so a determined process running as {{ svc_user }} could
# still replace the bin directory. This is a guard against accident, not a
# containment boundary.
"qubesair-console-binary":
  file.managed:
    - name: {{ bin_path }}
    - source: {{ bin_source }}
    - source_hash: sha256={{ bin_sha }}
    - user: root
    - group: root
    - mode: '0755'
    - require:
      - file: "qubesair-console-bin-dir"

{% if web_source and not web_sha %}
# Refuse rather than deliver an unverified UI. The page holds the operator's API
# token in localStorage and issues every fleet-mutating call, so "some HTML from
# somewhere" is not a lesser problem here than an unpinned binary.
"qubesair-console-web-sha-required":
  test.fail_without_changes:
    - name: |
        cfg.qubesair.console_web_source is set but console_web_sha256 is empty.

        Build and publish the frontend, then record its digest:

          cd console/frontend && npm run build
          tar -czf qubes-air-console-web.tar.gz -C dist .
          shasum -a 256 qubes-air-console-web.tar.gz

        Then set console_web_sha256 in the qubesair block of salt/config.jinja
        and re-run scripts/setup.sh.
    - failhard: True

{% elif web_source %}
# The built frontend, served by the console itself at the same origin as the
# API. Same-origin is what makes it work with no configuration: the frontend
# calls the relative path /api/v1, so there is no base URL to set and no CORS
# origin to allow.
#
# Delivered as ONE archive rather than a recursed directory. Vite emits
# content-hashed asset names, so every rebuild changes the file names; a
# file.recurse would leave every previous build's assets behind, and the qube
# would accumulate stale bundles that nothing ever serves and nothing removes.
# Unpacking into an emptied directory keeps what is on disk equal to what was
# built.
"qubesair-console-web-archive":
  file.managed:
    - name: {{ data_dir }}/web.tar.gz
    - source: {{ web_source }}
    - source_hash: sha256={{ web_sha }}
    - user: root
    - group: root
    - mode: '0644'
    - require:
      - file: "qubesair-console-data-dir"

"qubesair-console-web-unpack":
  cmd.run:
    - name: |
        set -eu
        rm -rf '{{ web_root }}'
        mkdir -p '{{ web_root }}'
        tar -xzf '{{ data_dir }}/web.tar.gz' -C '{{ web_root }}'
        test -f '{{ web_root }}/index.html'
        chown -R root:root '{{ web_root }}'
        chmod -R a+rX '{{ web_root }}'
    - runas: root
    - require:
      - file: "qubesair-console-web-archive"
    {#- Re-unpack only when the archive changed. Without this the directory is
        deleted and rebuilt on every apply, which serves 404s to anyone loading
        the page during the window. #}
    - onchanges:
      - file: "qubesair-console-web-archive"
{% endif %}

{% if var_file %}
# Operator-owned base var-file (endpoint, node, zone toggles). replace: False so
# it is created once as a skeleton and never overwritten — the operator's edits
# are the point of the file. It must exist even when empty: the console always
# passes -var-file for it and terraform fails the apply if the path is missing.
#
# It must NOT define remote_qubes. That variable is owned by the console, which
# renders it to {{ gen_var_file }} from the database before every invocation and
# passes it AFTER this file so the last -var-file wins. Defining it here would
# put two sources of truth in one apply.
"qubesair-console-terraform-varfile":
  file.managed:
    - name: {{ var_file }}
    - user: {{ svc_user }}
    - group: {{ svc_user }}
    - mode: '0600'
    - makedirs: True
    - dir_mode: '0750'
    - replace: False
    - contents: |
        # SPDX-License-Identifier: MIT — operator-owned, NOT managed by salt.
        # Created once by qubesair.console; your edits are preserved.
        #
        # Base terraform variables for the Qubes Air console. Do NOT define
        # remote_qubes here — the console renders it to {{ gen_var_file }} from
        # its database and passes it after this file, so anything set here would
        # be silently overridden anyway.
        #
        # Credentials do NOT belong here either: terraform writes every variable
        # value into state in plaintext. The console injects Proxmox credentials
        # into terraform's environment from its encrypted credential store.
    - require:
      - file: "qubesair-console-terraform-dir"
{% endif %}

# --- 3. Non-secret configuration --------------------------------------------
# Everything the console reads that is not a secret. Empty values are written
# rather than omitted so the file documents the full surface; config.go treats an
# empty environment variable as unset and keeps its default.
"qubesair-console-env":
  file.managed:
    - name: {{ env_file }}
    - user: {{ svc_user }}
    - group: {{ svc_user }}
    - mode: '0600'
    - contents: |
        # SPDX-License-Identifier: MIT — managed by qubesair.console
        # Non-secret console configuration. Secrets live in secrets.env.
        GIN_MODE=release
        QUBES_AIR_HOST={{ listen_host }}
        QUBES_AIR_PORT={{ listen_port }}
        QUBES_AIR_DATABASE_DSN={{ db_path }}
        QUBES_AIR_CORS_ORIGINS={{ cors | join(',') }}
        QUBES_AIR_ORCHESTRATOR_ENABLED={{ 'true' if orch else 'false' }}
        QUBES_AIR_TERRAFORM_DIR={{ tf_dir }}
        QUBES_AIR_TERRAFORM_BINARY={{ tf_bin }}
        QUBES_AIR_TERRAFORM_VAR_FILE={{ var_file }}
        QUBES_AIR_TERRAFORM_GENERATED_VAR_FILE={{ gen_var_file }}
        QUBES_AIR_AGENT_IDENTITY_DIR={{ identity_dir }}
        QUBES_AIR_AGENT_LISTEN={{ qa.get('agent_listen', '0.0.0.0:8443') }}
{%- if web_source %}
        QUBES_AIR_WEB_ROOT={{ web_root }}
{%- endif %}
        QUBES_AIR_APT_MIRROR={{ qa.get('apt_mirror', '') }}
        QUBES_AIR_APT_SECURITY_MIRROR={{ qa.get('apt_security_mirror', '') }}
        QUBES_AIR_AGENT_PACKAGE_URL={{ qa.get('agent_package_url', '') }}
        QUBES_AIR_AGENT_PACKAGE_SHA256={{ qa.get('agent_package_sha256', '') }}
        QUBES_AIR_AGENT_PACKAGE_VERSION={{ qa.get('agent_package_version', '') }}
        QUBES_AIR_AGENT_PROBE_INTERVAL_SECONDS={{ qa.get('agent_probe_interval_seconds', 60) }}
        QUBES_AIR_AGENT_PROBE_TIMEOUT_SECONDS={{ qa.get('agent_probe_timeout_seconds', 10) }}
        QUBES_AIR_AGENT_PROBE_SETTLE_SECONDS={{ qa.get('agent_probe_settle_seconds', 300) }}
        QUBES_AIR_AGENT_CERT_RENEW_INTERVAL_SECONDS={{ qa.get('agent_cert_renew_interval_seconds', 3600) }}
        QUBES_AIR_AGENT_CERT_RENEW_THRESHOLD_PERCENT={{ qa.get('agent_cert_renew_threshold_percent', 33) }}
    - require:
      - file: "qubesair-console-data-dir"

# --- 4. Secrets --------------------------------------------------------------
# Generated in the qube, once, and never rendered by salt. The path and posture
# are the ones config.jinja's own "qubesair secrets" note specifies:
# {data_dir}/secrets.env, 0600, owned by the service user, read via
# EnvironmentFile= so the values never appear in a unit file, a ps listing or
# this repository.
#
# WHY GENERATED HERE rather than placed by the operator or fetched from a vault:
#
#   * Not in config.jinja. That file is committed and scripts/setup.sh copies it
#     wholesale to /srv/salt/slchris. A key placed there is a key in git history
#     forever — which is exactly what its own note warns about.
#
#   * Not operator-supplied. The only constraint config.go enforces is "exactly
#     32 bytes", which a memorable passphrase satisfies. Generating from
#     /dev/urandom removes the chance to pick a weak one and keeps the key out of
#     shell history.
#
#   * Not from cfg.remotevm.grpc.vault_qube — yet. That would be the better home,
#     but the vault path that exists today (transport/grpc FetchClientMTLS)
#     fetches TRANSPORT certificates over a qrexec service, and nothing in the
#     console reads its encryption key from anywhere but the environment. Wiring
#     it means inventing a qubesair.VaultGet service plus a dom0 policy line and
#     having ExecStartPre stage the key into a tmpfs. That is a design, not a
#     config change, and half-wiring it would produce exactly the "looks done"
#     surface this deployment keeps getting bitten by. Named here so the gap is
#     known to be deliberate, and so the next person knows its shape.
#
# THE KEY CANNOT BE REGENERATED. It decrypts the agent CA private key and the
# Proxmox credential, both stored as ciphertext in {{ db_path }}
# (service/certs.go stores the CA in the credential store on first use). Lose it
# and the CA is unrecoverable: loadOrCreateCA finds a stored CA it cannot parse
# and refuses to mint a replacement rather than silently re-rooting the fleet's
# trust. Hence `unless` — this runs exactly once, and a re-apply must never
# overwrite it. `mv -n` is the second guard, in case the first is ever removed.
#
# The alphabet is restricted to [A-Za-z0-9] so the value is safe both as a
# systemd EnvironmentFile value and as something the preflight can source without
# quoting games. 32 alphanumerics is ~190 bits of entropy, and the AES-256
# requirement is a 32-BYTE key, which this satisfies literally.
"qubesair-console-secrets":
  cmd.run:
    - name: |
        set -eu
        umask 077
        tmp="$(mktemp '{{ data_dir }}/.secrets.XXXXXX')"
        {
          printf '# SPDX-License-Identifier: MIT — generated once by qubesair.console. DO NOT COMMIT.\n'
          printf '#\n'
          printf '# QUBES_AIR_ENCRYPTION_KEY decrypts the agent CA private key and the\n'
          printf '# Proxmox credential in %s.\n' '{{ db_path }}'
          printf '# There is no other copy. Back this file up offline; losing it means losing\n'
          printf '# the CA and re-provisioning every remote qube.\n'
          printf '#\n'
          printf '# Single-key form: always key_version 1. To rotate, move to\n'
          printf '# QUBES_AIR_ENCRYPTION_KEYS ("v1:...,v2:...") and run cmd/rotate-key; the\n'
          printf '# old version must stay listed until no row still references it.\n'
          printf 'QUBES_AIR_ENCRYPTION_KEY=%s\n' \
            "$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)"
          printf 'QUBES_AIR_API_TOKEN=%s\n' \
            "$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 48)"
        } > "$tmp"
        chown {{ svc_user }}:{{ svc_user }} "$tmp"
        chmod 0600 "$tmp"
        mv -n "$tmp" '{{ secret_file }}'
        rm -f "$tmp"
    - runas: root
    - unless: test -s '{{ secret_file }}'
    - require:
      - file: "qubesair-console-data-dir"

# --- 5. Preflight ------------------------------------------------------------
# Run by ExecStartPre, and runnable by hand for diagnosis. Its whole purpose is
# to convert silent degradation into a failed unit.
#
# The case that matters most is the encryption key. config.go does NOT fail when
# QUBES_AIR_ENCRYPTION_KEY is unset: it falls back to the constant
# devEncryptionKey, logs a warning, and carries on. The console then comes up,
# answers /health, provisions qubes — and mints the fleet's CA under a key that
# is published in the source repository. Everything reports success. That is the
# worst outcome available to this deployment, and a warning in a journal nobody
# reads is not a control. Refusing to start is.
"qubesair-console-preflight":
  file.managed:
    - name: {{ preflight }}
    - user: root
    - group: root
    - mode: '0755'
    - contents: |
        #!/bin/sh
        # SPDX-License-Identifier: MIT — managed by qubesair.console
        #
        # Startup preconditions for qubes-air-console. Any failure aborts the
        # unit, which (with Restart=on-failure and a start limit) lands it in
        # `failed` where `systemctl --failed` reports it.
        set -eu

        fail() {
            printf 'qubes-air-console preflight FAILED: %s\n' "$1" >&2
            exit 1
        }

        # --- binary -----------------------------------------------------------
        [ -x '{{ bin_path }}' ] || fail 'no executable at {{ bin_path }} (re-apply qubesair.console)'

        # Actually run it. A binary built for the wrong architecture is present,
        # executable and correctly hashed; it fails only when exec'd, and then
        # only as "Exec format error" from systemd — nothing that mentions the
        # build.
        '{{ bin_path }}' -version >/dev/null 2>&1 \
            || fail '{{ bin_path }} will not execute (wrong architecture, or built with CGO_ENABLED=0)'

        # --- secrets ----------------------------------------------------------
        [ -f '{{ secret_file }}' ] || fail 'missing {{ secret_file }} (re-apply qubesair.console)'

        mode="$(stat -c '%a' '{{ secret_file }}')"
        [ "$mode" = "600" ] || fail "{{ secret_file }} is mode $mode, expected 600"

        # shellcheck source=/dev/null
        . '{{ secret_file }}'

        [ -n "${QUBES_AIR_ENCRYPTION_KEY:-}" ] \
            || fail 'QUBES_AIR_ENCRYPTION_KEY is empty; the console would silently use the built-in development key and encrypt the CA with a key published in the source repo'

        # config.go requires exactly 32 bytes for AES-256 and refuses to start
        # otherwise — but only when the key is non-empty, which is why the
        # emptiness check above is separate and worded the way it is.
        #
        # Counted with wc -c, NOT with the shell's parameter-length form. Two
        # reasons, and the second bites at render time rather than run time:
        #   - Go's len() counts BYTES; the shell's form counts characters, so a
        #     non-ASCII key would pass here and be rejected by the console.
        #   - The brace-hash spelling of that form is the Jinja COMMENT opener.
        #     Salt renders this file through Jinja before it is ever a shell
        #     script, so it silently swallows every line up to the next comment
        #     terminator — which lands mid-state, eats a block-closing tag, and
        #     reports a nesting error a long way from the actual cause.
        keylen="$(printf %s "$QUBES_AIR_ENCRYPTION_KEY" | wc -c)"
        [ "$keylen" -eq 32 ] \
            || fail "QUBES_AIR_ENCRYPTION_KEY is $keylen bytes, must be exactly 32 for AES-256"

        [ "$QUBES_AIR_ENCRYPTION_KEY" != 'qubes-air-dev-encryption-key32!!' ] \
            || fail 'QUBES_AIR_ENCRYPTION_KEY is the well-known development key from config.go'

        [ -n "${QUBES_AIR_API_TOKEN:-}" ] \
            || fail 'QUBES_AIR_API_TOKEN is empty; the console would serve /api/v1 — including credential management — with authentication disabled'

        # --- writable state ---------------------------------------------------
        # Checked as directories, not as the database file: SQLite runs in WAL
        # mode here (the DSN adds _journal_mode=WAL), so it creates and rewrites
        # qubes-air.db-wal and -shm alongside the database. A writable DB file in
        # a read-only directory fails on the first write, not at open.
        [ -w '{{ db_dir }}' ] || fail '{{ db_dir }} is not writable by this service'
        [ -w '{{ identity_dir }}' ] || fail '{{ identity_dir }} is not writable by this service'

        # The identity directory holds agent private keys. If something widened
        # it, say so before writing more keys into it.
        idmode="$(stat -c '%a' '{{ identity_dir }}')"
        [ "$idmode" = "700" ] \
            || fail "{{ identity_dir }} is mode $idmode, expected 700 — it holds agent PRIVATE KEYS"

        {%- if orch %}

        # --- terraform --------------------------------------------------------
        # Only when orchestration is enabled. With it disabled the console flips
        # database status without invoking terraform and none of this applies.
        command -v '{{ tf_bin }}' >/dev/null 2>&1 || [ -x '{{ tf_bin }}' ] \
            || fail 'orchestration is enabled but {{ tf_bin }} is missing (the qubesair install state puts it in the TEMPLATE; installing it in the AppVM would not survive a reboot)'

        [ -d '{{ tf_dir }}' ] || fail 'orchestration is enabled but {{ tf_dir }} does not exist'

        ls '{{ tf_dir }}'/*.tf >/dev/null 2>&1 \
            || fail '{{ tf_dir }} contains no .tf files; copy the terraform root from the qubes-air repo into it'
        {%- if var_file %}

        [ -f '{{ var_file }}' ] || fail 'missing {{ var_file }} (re-apply qubesair.console)'
        {%- endif %}

        # The console never runs `terraform init` — it goes straight to plan and
        # apply. Without .terraform/ the first apply fails with a provider error
        # minutes into a job, recorded as a failed provision rather than as a
        # missing setup step. Catch it at startup, when the message can still
        # name the command to run.
        [ -d '{{ tf_dir }}/.terraform' ] \
            || fail 'terraform has not been initialised in {{ tf_dir }}; run: cd {{ tf_dir }} && HOME={{ home_dir }} {{ tf_bin }} init'
        {%- endif %}

        exit 0
    - require:
      - file: "qubesair-console-data-dir"

# --- 6. systemd unit ---------------------------------------------------------
# Written to the bind-dirs SOURCE, not to /etc/systemd/system.
#
# This is the subtlety that breaks the obvious version: bind-dirs.sh populates
# /rw/bind-dirs/<path> from the CURRENT content of <path> the first time it sees
# a bind, and it runs at early boot. A unit written straight to
# /etc/systemd/system now is not captured — at the next boot bind-dirs
# initialises its copy from the template, which has no such unit, and the file is
# gone. Writing the canonical copy into /rw/bind-dirs and letting the bind mount
# project it into /etc is what actually survives.
#
# Confirmed on R4.3 hardware (qubes-core-agent 4.3.45-1+deb13u1) while fixing the
# same defect in mgmt.remotevm.relay: with the file written straight to the real
# path and listed in binds, it is gone after one reboot and nothing reports an
# error; written to /rw/bind-dirs, it survives.
"qubesair-console-unit":
  file.managed:
    - name: /rw/bind-dirs/etc/systemd/system/qubes-air-console.service
    - makedirs: True
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        # SPDX-License-Identifier: MIT — managed by qubesair.console
        [Unit]
        Description=Qubes Air console
        Documentation=file://{{ env_file }}

        # RequiresMountsFor is the ordering that matters. Every path this unit
        # needs — binary, configuration, secrets, database — is under /rw, a
        # separate volume mounted during boot. Without this the unit is eligible
        # to start before /rw is there and fails on a missing EnvironmentFile on
        # a machine that is otherwise fine. Being boot-timing dependent, it
        # reproduces intermittently, which is the worst way to find it.
        RequiresMountsFor=/rw
        After=qubes-mount-dirs.service network-online.target qubes-qrexec-agent.service
        Wants=network-online.target

        # A failed precondition here is almost always permanent: a missing
        # binary, a key that is not 32 bytes, an uninitialised terraform
        # directory. Restart=on-failure with a start limit rides out a genuinely
        # transient fault (the listen port still held by the previous process
        # during a restart) and then gives up, leaving the unit in `failed` where
        # `systemctl --failed` reports it.
        #
        # Restart=always — which mgmt/remotevm/grpc-relay.sls uses — would
        # instead show "activating (auto-restart)" forever: a broken console that
        # looks busy rather than broken. This project's recurring defect is the
        # failure that looks like success, so this unit is configured to stop
        # rather than to keep looking alive.
        #
        # After fixing the cause:
        #   systemctl reset-failed qubes-air-console && systemctl start qubes-air-console
        StartLimitIntervalSec=300
        StartLimitBurst=5

        [Service]
        Type=simple

        # Not root. The console binds a port above 1024, shells out to terraform
        # and writes its own state; none of that needs privilege, and the process
        # holds the fleet's CA. It runs as the qube's existing `user` rather than
        # a dedicated system account on purpose: /etc/passwd is on the root
        # volume and is reset from the template on every boot, so a user created
        # by this state would exist today and be gone tomorrow, leaving the unit
        # failing with "Failed to determine user credentials".
        User={{ svc_user }}
        Group={{ svc_user }}

        # No leading '-' on either file: if configuration or secrets are missing
        # the unit must fail with "Failed to load environment files" rather than
        # start with an empty environment and quietly fall back to defaults —
        # which for the encryption key means the built-in development key.
        EnvironmentFile={{ env_file }}
        EnvironmentFile={{ secret_file }}

        # terraform writes a plugin cache and CLI state under $HOME. ProtectHome
        # below hides the real /home/user, so HOME is redirected to a directory
        # this service owns.
        Environment=HOME={{ home_dir }}

        # And because HOME was redirected, terraform no longer finds the
        # .terraformrc that qubesair.install symlinks into the real home. It
        # has no system-wide config path on Linux — $HOME/.terraformrc or
        # TF_CLI_CONFIG_FILE, nothing else — so without this it silently ignores
        # the pinned provider mirror and reaches for the public registry.
        # Silently: `terraform init` succeeds either way, and the difference only
        # shows up as a provider version nobody chose, or as a failure on a host
        # with no route to the internet.
        Environment=TF_CLI_CONFIG_FILE={{ tfrc }}

        # Only reached if QUBES_AIR_DATABASE_DSN were somehow unset, in which
        # case config.go defaults to the relative path "./qubes-air.db". Pointing
        # the working directory at the data directory means even that degraded
        # case puts the database somewhere sane instead of in / .
        WorkingDirectory={{ data_dir }}

        # Refuse to start rather than start wrong. See {{ preflight }}.
        ExecStartPre={{ preflight }}
        ExecStart={{ bin_path }}

        Restart=on-failure
        RestartSec=5

        # 0077: SQLite creates the database 0644 by default. That database holds
        # the CA private key and the Proxmox credential as ciphertext, which is
        # precisely the material an offline attack wants.
        UMask=0077

        NoNewPrivileges=yes
        ProtectHome=yes
        PrivateTmp=yes

        # 'full' rather than 'strict', matching the agent: it protects /usr,
        # /boot and /efi — enough to stop a compromised console replacing the
        # binary it runs under — without making the whole filesystem read-only.
        ProtectSystem=full

        # Everything this service must WRITE, enumerated.
        #
        # This list exists because of a failure already paid for on real
        # hardware: the agent's ProtectSystem=full made /etc read-only, its
        # identity lived in /etc/qubes-air, and certificate renewal silently
        # became impossible the moment the agent had to write rather than read.
        # Every unit test wrote to a temp directory with no systemd sandbox, so
        # the suite passed while renewal could never succeed on a real host. The
        # error surfaced as "read-only file system" three layers below anything
        # that mentions systemd.
        #
        # The console writes MORE than the agent did: the SQLite database plus
        # its -wal and -shm sidecars, agent identity documents, terraform's
        # generated var-file, terraform state and the .terraform provider
        # directory, and terraform's cache under HOME. All of it is under
        # {{ data_dir }}, which is on /rw — a path ProtectSystem=full does not
        # cover — so today this line changes nothing.
        #
        # It is here for whoever tightens this to ProtectSystem=strict. At that
        # moment /rw becomes read-only too, and without this the console would
        # keep serving, keep answering /health, and fail only when it next tried
        # to persist something. Enumerated now, while the reasons are known,
        # rather than reconstructed from a stack trace later.
        ReadWritePaths={{ data_dir }}

        [Install]
        WantedBy=multi-user.target

# bind-dirs: project the unit back into /etc/systemd/system on every boot.
"qubesair-console-bind-dirs":
  file.managed:
    - name: /rw/config/qubes-bind-dirs.d/50_qubesair_console.conf
    - makedirs: True
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        # Managed by qubesair.console
        binds+=( '/etc/systemd/system/qubes-air-console.service' )

# Make the unit real for THIS boot. The .conf above only takes effect at the next
# one — bind-dirs.sh has long since run by the time salt gets here — so the mount
# is performed now as well. `mountpoint -q ||` makes it a no-op on later runs,
# and the target must be created first because mount --bind needs an existing
# file to mount over.
"qubesair-console-unit-activate":
  cmd.run:
    - name: |
        set -e
        target=/etc/systemd/system/qubes-air-console.service
        [ -e "$target" ] || : > "$target"
        chmod 0644 "$target"
        mountpoint -q "$target" \
          || mount --bind /rw/bind-dirs/etc/systemd/system/qubes-air-console.service "$target"
        systemctl daemon-reload
    - runas: root
    - require:
      - file: "qubesair-console-unit"
      - file: "qubesair-console-bind-dirs"

# --- 7. Start on every boot --------------------------------------------------
# rc.local, not `systemctl enable`.
#
# `enable` writes a symlink into /etc/systemd/system/multi-user.target.wants/,
# which is on the root volume and is discarded with it. The console would start
# today and never again, with `systemctl is-enabled` still reporting "enabled" on
# the boot where it did not start — the failure disguised as success, once more.
#
# rc.local runs from qubes-misc-post.service on every AppVM boot; the repo
# already depends on this for sshd (mgmt/remote-debug/configure.sls, with the
# measured ordering) and for tailscale's dnsmasq. blockreplace rather than
# file.managed so this coexists with those blocks instead of overwriting them.

# blockreplace fails outright on a missing file, and it is only Qubes convention
# — not a guarantee — that an AppVM ships /rw/config/rc.local. replace: False
# creates it when absent and never touches an existing one, so the block below
# cannot fail for a reason that has nothing to do with the console.
"qubesair-console-rc-local-exists":
  file.managed:
    - name: /rw/config/rc.local
    - user: root
    - group: root
    - mode: '0755'
    - replace: False
    - contents: |
        #!/bin/sh

"qubesair-console-rc-local":
  file.blockreplace:
    - name: /rw/config/rc.local
    - marker_start: "# >>> qubesair-console >>>"
    - marker_end: "# <<< qubesair-console <<<"
    - append_if_not_found: True
    - show_changes: True
    - content: |
        # Managed by qubesair.console — do not edit between markers.
        # Only the start belongs here; `systemctl enable` does not survive the
        # root-volume reset (see the note on the unit above).
        #
        # Installing the unit as a fallback used to be done here too, on the
        # belief that bind-dirs cannot bind over a path the template does not
        # ship. The shipped script (qubes-core-agent 4.3.45-1+deb13u1) creates
        # the missing target itself whenever the /rw copy exists, which the unit
        # state above guarantees; it only skips an entry when NEITHER side
        # exists. Verified on R4.3 hardware via mgmt.remotevm.relay: apply,
        # reboot, file still present and still bound, with no fallback involved.
        systemctl daemon-reload 2>/dev/null || true
        systemctl start qubes-air-console 2>/dev/null || true
    - require:
      - file: "qubesair-console-rc-local-exists"

"qubesair-console-rc-local-shebang":
  cmd.run:
    - name: |
        f=/rw/config/rc.local
        head -n1 "$f" | grep -q '^#!' || sed -i '1i #!/bin/sh' "$f"
        chmod 0755 "$f"
    - runas: root
    - require:
      - file: "qubesair-console-rc-local"

# --- 8. Start now, and PROVE it is serving -----------------------------------
# Type=simple means `systemctl start` returns success as soon as systemd has
# forked the process — before the console has loaded its configuration, opened
# the database or bound the port. A console that exits a millisecond later still
# produces a clean `systemctl start`, and a salt run that stops there reports a
# green highstate for a service that is already dead.
#
# So the state polls /health until the console answers. First start is also when
# the database is created and migrated and the agent CA is minted, so the wait is
# not padding: it is the window in which that work happens, and the retries are
# what stop this racing it.
#
# On failure it dumps status and the journal, because the operator's next
# question is always "why", and the answer is a log line the console already
# printed.
"qubesair-console-start":
  cmd.run:
    - name: |
        set -e
        systemctl restart qubes-air-console
        for i in $(seq 1 30); do
            if python3 -c "import urllib.request,sys; \
                sys.exit(0 if urllib.request.urlopen('http://{{ listen }}/health', timeout=3).status == 200 else 1)" \
                2>/dev/null; then
                echo "qubes-air-console is serving on {{ listen }}"
                exit 0
            fi
            # A unit that has already given up will never answer; stop waiting
            # for it and show why now rather than after the full timeout.
            if systemctl is-failed --quiet qubes-air-console; then
                break
            fi
            sleep 2
        done
        echo "---- qubes-air-console did not become healthy ----" >&2
        systemctl status --no-pager --full qubes-air-console >&2 || true
        journalctl -u qubes-air-console --no-pager -n 60 >&2 || true
        exit 1
    - runas: root
    - require:
      - file: "qubesair-console-binary"
      - file: "qubesair-console-env"
      - file: "qubesair-console-preflight"
      - file: "qubesair-console-identity-dir"
      - file: "qubesair-console-home-dir"
      - file: "qubesair-console-terraform-dir"
      - cmd: "qubesair-console-secrets"
      - cmd: "qubesair-console-unit-activate"
      - cmd: "qubesair-console-rc-local-shebang"

"qubesair-console-next-steps":
  test.show_notification:
    - text: |
        qubes-air-console is serving on {{ listen }}.

        1. Read the API token (required on every /api/v1 request):
             sudo grep QUBES_AIR_API_TOKEN {{ secret_file }}

        2. BACK UP {{ secret_file }} OFFLINE.
           QUBES_AIR_ENCRYPTION_KEY decrypts the agent CA private key and the
           Proxmox credential in {{ db_path }}. There is no second copy and no
           recovery path: without it the CA cannot be read, the console refuses
           to mint a replacement, and every remote qube must be re-provisioned.

        3. Store the Proxmox credential — via the API, never in a file. It is
           encrypted with the key above and read back only when terraform runs:
             curl -sS -X POST http://{{ listen }}/api/v1/credentials \
                  -H "Authorization: Bearer $TOKEN" \
                  -H 'Content-Type: application/json' \
                  -d '{"name":"pve","type":"proxmox","secret":"..."}'
           Then point the zone's proxmox.credential_id at the returned id.

        4. First start created the database and minted the agent CA. Confirm:
             journalctl -u qubes-air-console | grep 'created a new agent CA'
        {%- if listen_host in ('127.0.0.1', 'localhost', '::1') %}

        NOTE: the console is bound to {{ listen_host }}, so it is reachable only
        from inside this qube. That is deliberate — it holds the CA and the PVE
        credential. Reaching it over the tailnet needs BOTH a bind address change
        (cfg.qubesair.listen) and an nft accept in custom-input, which an AppVM
        leaves empty by default. Change one without the other and it will look
        broken rather than exposed, which is the right way round.
        {%- endif %}
        {%- if not orch %}

        NOTE: orchestration is DISABLED (cfg.qubesair.orchestrator_enabled is
        False). start/stop only flip database status; terraform is never invoked
        and no VM is created.
        {%- endif %}
    - require:
      - cmd: "qubesair-console-start"

{% endif %}{# console_binary_sha256 present #}

{% else %}

"qubesair-console-disabled-note":
  test.show_notification:
    - text: |
        qubesair.console: cfg.qubesair.enabled is not True — nothing was
        deployed. Set it in salt/config.jinja and re-run scripts/setup.sh.

        This state reads the qubesair block FLAT (cfg.qubesair.<key>), matching
        the layout config.jinja already defines. It adds two keys of its own,
        neither of which has a usable default:

          console_binary_sha256   sha256 of the hand-built console binary
                                  (required — the state refuses to deploy an
                                  unverified binary)
          console_binary_source   salt:// URL of that binary
                                  (default: salt://qubesair/files/qubes-air-console)

        Optional, with defaults: service_user ("user"), cors_origins ([] =>
        the listen origin).

{% endif %}{# enabled #}
{% endif %}{# not dom0 #}
