{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Join an ordinary qube to the tailnet as its OWN node (runs IN the qube).

Unlike mgmt.tailscale.configure, which turns sys-tailscale into a gateway
(downstream DNS redirect, vif handling, advertised subnet routes/exit node),
this state only makes the target qube a plain tailnet member so it gets its own
100.x.y.z address. Use it for mgmt-jump: after this, `ssh user@<100.x>` reaches
the remote-debug jump qube directly over the mesh, no LAN port-forward.

It does NOT touch sshd or the firewall: mgmt.remote-debug.configure already
installs a hardened sshd and accepts inbound :22 in `ip qubes custom-input`,
which covers packets arriving on tailscale0 too. It also does NOT advertise
routes or run dnsmasq — that is the gateway's job.

    sudo qubesctl --skip-dom0 --targets=mgmt-jump state.apply mgmt.tailscale.node

Prereqs: mgmt.tailscale.install applied to this qube's TEMPLATE (tailscaled in
the image), and cfg.tailscale.enabled with a non-empty login_server.
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set ts = cfg.get('tailscale', {}) -%}
{%- set login_server = ts.get('login_server', '') -%}
{%- set auth_key = ts.get('auth_key', '') -%}
{%- set accept_dns = ts.get('accept_dns', True) -%}
{%- set accept_routes = ts.get('accept_routes', False) -%}
{#- A node is named after the qube unless an explicit per-node override is in
    ts.node_hostnames keyed by qube name. Never reuse ts.hostname here: that is
    the gateway's name and would give every node the same tailnet hostname. -#}
{%- set node_hostnames = ts.get('node_hostnames', {}) -%}
{%- set qube_name = grains['id'] -%}
{%- set hostname = node_hostnames.get(qube_name, '') -%}

{% if grains['nodename'] != 'dom0' %}
{% if ts.get('enabled', False) %}

{% if not login_server %}

"tailscale-node-login-server-required":
  test.fail_without_changes:
    - name: |
        cfg.tailscale.login_server is empty but tailscale.enabled is True.
        Set the Headscale control URL in salt/config.jinja and re-run
        scripts/setup.sh.
    - failhard: True

{% else %}

# --- 1. Persist /var/lib/tailscale across the AppVM root-volume reset -------
# Same reasoning as mgmt.tailscale.configure: without this the AppVM
# re-registers as a NEW node every boot, orphaning entries on Headscale.
"tailscale-node-bind-dirs":
  file.managed:
    - name: /rw/config/qubes-bind-dirs.d/50_tailscale.conf
    - makedirs: True
    - mode: '0644'
    - contents: |
        # Managed by mgmt.tailscale.node
        binds+=( '/var/lib/tailscale' )

# bind-dirs.sh only runs at early boot, so it has NOT mounted our bind yet this
# run. mount --bind it now, before the daemon ever starts, or the node key is
# written to the ephemeral root volume and lost on reboot.
"tailscale-node-bind-dirs-seed":
  cmd.run:
    - name: |
        set -e
        mkdir -p /rw/bind-dirs/var/lib/tailscale
        chmod 0700 /rw/bind-dirs/var/lib/tailscale
        mkdir -p /var/lib/tailscale
        mountpoint -q /var/lib/tailscale \
          || mount --bind /rw/bind-dirs/var/lib/tailscale /var/lib/tailscale
    - runas: root
    - require:
      - file: "tailscale-node-bind-dirs"

# --- 2. Bring up tailscaled ------------------------------------------------
"tailscale-node-daemon-up":
  cmd.run:
    - name: systemctl enable --now tailscaled
    - runas: root
    - require:
      - cmd: "tailscale-node-bind-dirs-seed"

# --- 3. Join the tailnet (no advertised routes / exit node) ----------------
{#- Stage the pre-auth key in tmpfs-backed /run, never on the cmdline (salt
    copies the rendered command into its log/comment and ps). -#}
{%- set authkey_path = '/run/tailscale-node-authkey' -%}
{%- set up_args = '--login-server=' ~ login_server -%}
{%- if auth_key %}{% set up_args = up_args ~ ' --auth-key-file=' ~ authkey_path %}{% endif -%}
{%- set up_args = up_args ~ ' --accept-dns=' ~ ('true' if accept_dns else 'false') -%}
{%- if accept_routes %}{% set up_args = up_args ~ ' --accept-routes' %}{% endif -%}
{%- if hostname %}{% set up_args = up_args ~ ' --hostname=' ~ hostname %}{% endif -%}

{% if auth_key %}
"tailscale-node-authkey-file":
  file.managed:
    - name: {{ authkey_path }}
    - contents: {{ auth_key | yaml_encode }}
    - mode: '0600'
    - user: root
    - group: root
    - show_changes: False
    - require:
      - cmd: "tailscale-node-daemon-up"
{% endif %}

"tailscale-node-join":
  cmd.run:
    - name: tailscale up {{ up_args }}
    - runas: root
    - require:
      - cmd: "tailscale-node-daemon-up"
{%- if auth_key %}
      - file: "tailscale-node-authkey-file"
{%- endif %}
    - unless: tailscale status --json 2>/dev/null | grep -q '"BackendState":[[:space:]]*"Running"'

{% if auth_key %}
"tailscale-node-authkey-file-remove":
  file.absent:
    - name: {{ authkey_path }}
    - require:
      - cmd: "tailscale-node-join"
{% endif %}

# --- 4. Reconcile flags on an already-joined node without re-running `up` ---
{%- set set_args = '--accept-dns=' ~ ('true' if accept_dns else 'false') -%}
{%- set set_args = set_args ~ ' --accept-routes=' ~ ('true' if accept_routes else 'false') -%}
{%- if hostname %}{% set set_args = set_args ~ ' --hostname=' ~ hostname %}{% endif -%}
"tailscale-node-reconcile-flags":
  cmd.run:
    - name: tailscale set {{ set_args }}
    - runas: root
    - onlyif: tailscale status --json 2>/dev/null | grep -q '"BackendState":[[:space:]]*"Running"'
    - require:
      - cmd: "tailscale-node-join"

"tailscale-node-address":
  cmd.run:
    - name: tailscale ip -4 2>/dev/null || true
    - runas: root
    - require:
      - cmd: "tailscale-node-join"

{% endif %}
{% else %}
"tailscale-node-disabled-note":
  test.show_notification:
    - text: |
        mgmt.tailscale.node: cfg.tailscale.enabled is False — not joining
        {{ qube_name }} to any tailnet.
{% endif %}
{% endif %}
