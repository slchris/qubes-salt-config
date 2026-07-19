{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Configure the sys-tailscale gateway (runs IN the qube, not dom0).

Does the Qubes-specific work that makes tailscaled survive and behave as a NetVM:

  1. bind-dirs: persist /var/lib/tailscale (node key/state) across the AppVM
     root-volume reset. Without this the qube re-registers as a NEW Headscale
     node every boot, orphaning old entries.
  2. qubes-firewall-user-script (marker-merged, same pattern as remote-debug /
     hotspot):
       - accept inbound SSH on custom-input (if ssh == "sshd");
       - DNAT downstream :53 -> 100.100.100.100 so AppVMs behind this gateway
         can resolve MagicDNS (DNS does not propagate downstream otherwise).
  3. join the tailnet non-interactively against your Headscale via
     `tailscale up --login-server ... [--authkey ...]`, guarded to run once
     (state now persists), with roles: exit-node / subnet-routes / accept-dns.
  4. optional plain sshd (key-only) so you can `ssh <tailnet-ip>` into Qubes.

Prereqs: mgmt.tailscale.install applied to the template, and the qube created
(mgmt.tailscale.create) and started.

Deploy (from dom0):
  sudo qubesctl --skip-dom0 --targets=sys-tailscale state.apply mgmt.tailscale.configure
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set ts = cfg.get('tailscale', {}) -%}
{%- set rd = cfg.get('remote_debug', {}) -%}
{%- set login_server = ts.get('login_server', '') -%}
{%- set auth_key = ts.get('auth_key', '') -%}
{%- set accept_dns = ts.get('accept_dns', True) -%}
{%- set hostname = ts.get('hostname', '') -%}
{%- set exit_node = ts.get('advertise_exit_node', False) -%}
{%- set routes = ts.get('advertise_routes', []) -%}
{%- set accept_routes = ts.get('accept_routes', False) -%}
{%- set fwd_dns = ts.get('forward_downstream_dns', True) -%}
{%- set ssh_mode = ts.get('ssh', 'sshd') -%}
{%- set keys = ts.get('authorized_keys', []) or rd.get('authorized_keys', []) -%}

{% if grains['nodename'] != 'dom0' %}
{% if ts.get('enabled', False) %}

# login_server is mandatory for a self-hosted Headscale gateway. If it is empty
# we must NOT proceed — silently dropping the flag would make `tailscale up` fall
# back to the PUBLIC Tailscale SaaS control server. Emit a single hard-failing
# state (execution-time, no jinja `raise` dependency) and render nothing else, so
# the run aborts with an actionable message and never touches the network.
{% if not login_server %}

"tailscale-login-server-required":
  test.fail_without_changes:
    - name: |
        cfg.tailscale.login_server is empty but tailscale.enabled is True.
        Set the Headscale control URL (e.g. https://headscale.example.com) in
        salt/config.jinja and re-run scripts/setup.sh.
    - failhard: True

{% else %}

# --- 1. Persist tailscale state across the AppVM root-volume reset ------------
"tailscale-bind-dirs":
  file.managed:
    - name: /rw/config/qubes-bind-dirs.d/50_tailscale.conf
    - makedirs: True
    - mode: '0644'
    - contents: |
        # Managed by mgmt.tailscale.configure
        binds+=( '/var/lib/tailscale' )

# CRITICAL ordering: Qubes only processes qubes-bind-dirs.d/*.conf and performs
# the bind mount during early boot (bind-dirs.sh). Since we write the .conf AFTER
# this boot already happened, /var/lib/tailscale is NOT yet bind-mounted this run.
# If tailscaled started now it would write its node key to the ephemeral root
# volume and lose it on the next reboot (re-registering as a NEW Headscale node —
# exactly what this module exists to prevent). So we also `mount --bind` the /rw
# source over /var/lib/tailscale for THIS run, before the daemon is ever started.
# On later boots bind-dirs.sh does the same mount; the `mountpoint -q ||` guard
# makes this a no-op then.
"tailscale-bind-dirs-seed":
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
      - file: "tailscale-bind-dirs"

# --- 2. qubes-firewall-user-script: inbound SSH + downstream DNS redirect -----
# Marker-merged into the shared script so it coexists with any other blocks and
# re-applies on every boot. We rewrite only our own >>> tailscale >>> section.
#
# All rules are pure nftables against the `ip qubes` table — Qubes 4.2/4.3 is
# nftables-native, debian-13-minimal ships no iptables, and there is no PR-QBS
# chain. We follow the repo's own remote-debug/netfw.sls convention: create any
# custom NAT chain before adding rules to it, and make adds idempotent so the
# boot-time re-run does not stack duplicates.
#
# Downstream DNS note (why REDIRECT to a LOCAL forwarder, not DNAT to Quad100):
# 100.100.100.100 (MagicDNS) is a virtual address that tailscaled answers only
# for packets that originate/terminate LOCALLY on this gateway — a forwarded
# vif->100.100.100.100 packet is not routable and gets blackholed. So we run a
# local dnsmasq (see mgmt.tailscale.install) that itself queries 100.100.100.100,
# and REDIRECT downstream :53 (aimed at the Qubes virtual NS 10.139.1.1/.2) to
# this host's local resolver. REDIRECT rewrites the dst to the local box, so the
# packet takes the INPUT path to dnsmasq — no forwarding, no SNAT, no reliance on
# the VIP being forwardable.
"tailscale-fw-script":
  file.blockreplace:
    - name: /rw/config/qubes-firewall-user-script
    - marker_start: "# >>> tailscale >>>"
    - marker_end: "# <<< tailscale <<<"
    - append_if_not_found: True
    - show_changes: True
    - content: |
        # Managed by mgmt.tailscale.configure — do not edit between markers.
        {%- if ssh_mode == 'sshd' %}
        # Accept inbound SSH. Qubes AppVMs drop input via an empty custom-input.
        # Guard on the rendered rule text so the boot re-run does not stack a
        # duplicate each time (a bare `flush custom-input` would clobber other
        # modules' rules on a shared qube, so we add-if-absent instead).
        nft list chain ip qubes custom-input 2>/dev/null | grep -q 'tcp dport 22' \
          || nft add rule ip qubes custom-input tcp dport 22 ct state new,established,related counter accept 2>/dev/null || true
        {%- endif %}
        {%- if fwd_dns %}
        # Downstream DNS -> local dnsmasq (which forwards to MagicDNS 100.100.100.100).
        # Own prerouting NAT chain, recreated idempotently like netfw.sls.
        nft add chain ip qubes custom-dnat-dns '{ type nat hook prerouting priority -99 ; policy accept ; }' 2>/dev/null || true
        nft flush chain ip qubes custom-dnat-dns 2>/dev/null || true
        # REDIRECT (dst -> local host) the DNS the AppVMs actually send: queries to
        # the Qubes virtual nameservers 10.139.1.1 / 10.139.1.2 arriving on a vif.
        nft add rule ip qubes custom-dnat-dns iifname "vif*" ip daddr { 10.139.1.1, 10.139.1.2 } udp dport 53 counter redirect
        nft add rule ip qubes custom-dnat-dns iifname "vif*" ip daddr { 10.139.1.1, 10.139.1.2 } tcp dport 53 counter redirect
        # After REDIRECT the packet is locally destined, so it hits the input hook
        # (default-drop) — accept the redirected DNS so it reaches dnsmasq on :53.
        nft add rule ip qubes custom-input iifname "vif*" udp dport 53 ct state new,established,related counter accept 2>/dev/null || true
        nft add rule ip qubes custom-input iifname "vif*" tcp dport 53 ct state new,established,related counter accept 2>/dev/null || true
        {%- endif %}

"tailscale-fw-ensure-shebang":
  cmd.run:
    - name: |
        f=/rw/config/qubes-firewall-user-script
        head -n1 "$f" | grep -q '^#!' || sed -i '1i #!/bin/sh' "$f"
        chmod 0755 "$f"
    - runas: root
    - require:
      - file: "tailscale-fw-script"

"tailscale-fw-apply-now":
  cmd.run:
    - name: /rw/config/qubes-firewall-user-script
    - runas: root
    - require:
      - cmd: "tailscale-fw-ensure-shebang"

# --- 3. Bring up tailscaled and join the Headscale tailnet -------------------
"tailscale-daemon-up":
  cmd.run:
    - name: systemctl enable --now tailscaled
    - runas: root
    - require:
      - cmd: "tailscale-bind-dirs-seed"

{% if fwd_dns %}
# Local DNS forwarder for downstream AppVMs. The nft REDIRECT above lands their
# :53 on THIS host; dnsmasq (bound to the vif-facing address, queried locally)
# forwards to MagicDNS 100.100.100.100 — which tailscaled answers because the
# query now originates locally. Config lives in /etc but is reset from the
# template each boot, so it is also written to /rw and restored via rc.local.
"tailscale-dnsmasq-config":
  file.managed:
    - name: /rw/config/tailscale/dnsmasq-tailscale.conf
    - makedirs: True
    - mode: '0644'
    - contents: |
        # SPDX-License-Identifier: MIT — mgmt.tailscale (downstream DNS forwarder)
        # Forward everything to the tailnet resolver; tailscaled serves MagicDNS
        # and (with --accept-dns) global DNS on 100.100.100.100 for local queries.
        no-resolv
        server=100.100.100.100
        # CRITICAL: nft `redirect` rewrites the dst to the address of the interface
        # the packet ARRIVED on — i.e. this gateway's vif-facing IP (10.137.x.x),
        # NOT 127.0.0.1. So dnsmasq must bind the vif side, not just loopback.
        # `interface=vif*` + `bind-dynamic` binds each vif as AppVMs start/stop
        # (bind-dynamic tolerates interfaces coming and going; without it dnsmasq
        # would fail to start when no vif exists yet).
        bind-dynamic
        interface=vif*
        listen-address=127.0.0.1
        cache-size=1000

# Restore the dnsmasq drop-in and (re)start it on every boot, after tailscaled.
"tailscale-dnsmasq-rc-local":
  file.blockreplace:
    - name: /rw/config/rc.local
    - marker_start: "# >>> tailscale-dnsmasq >>>"
    - marker_end: "# <<< tailscale-dnsmasq <<<"
    - append_if_not_found: True
    - content: |
        install -D -m 0644 /rw/config/tailscale/dnsmasq-tailscale.conf \
          /etc/dnsmasq.d/10-tailscale.conf 2>/dev/null || true
        # Start after tailscaled so 100.100.100.100 is answerable.
        ( for i in $(seq 1 30); do tailscale status >/dev/null 2>&1 && break; sleep 1; done
          systemctl restart dnsmasq 2>/dev/null || true ) &

"tailscale-dnsmasq-rc-shebang":
  cmd.run:
    - name: |
        f=/rw/config/rc.local
        head -n1 "$f" | grep -q '^#!' || sed -i '1i #!/bin/sh' "$f"
        chmod 0755 "$f"
    - runas: root
    - require:
      - file: "tailscale-dnsmasq-rc-local"

# Apply the drop-in now (this run) and restart dnsmasq after the daemon is up.
"tailscale-dnsmasq-apply-now":
  cmd.run:
    - name: |
        install -D -m 0644 /rw/config/tailscale/dnsmasq-tailscale.conf \
          /etc/dnsmasq.d/10-tailscale.conf
        systemctl enable dnsmasq 2>/dev/null || true
        systemctl restart dnsmasq
    - runas: root
    - require:
      - file: "tailscale-dnsmasq-config"
      - cmd: "tailscale-daemon-up"
{% endif %}

{#- Where the pre-auth key is staged. Under /run so it is tmpfs-backed and
    cannot survive a reboot even if a failed run skips the removal below. -#}
{%- set authkey_path = '/run/tailscale-authkey' -%}

{#- Build the `tailscale up` args as an inline string. Plain {% set %} + string
    concat (no {% do %}/list mutation) to match the rest of the repo's Jinja
    style and avoid depending on the jinja `do` extension. -#}
{%- set up_args = '--login-server=' ~ login_server -%}
{#- The auth key is passed by FILE, never on the command line.

    salt's cmd.run puts the rendered command into its return `comment`, so an
    inline --authkey= lands in dom0's /var/log/qubes/mgmt-<vm>.log and on the
    terminal, and is visible in `ps` for as long as the command runs. A
    pre-auth key is a credential that joins a machine to the tailnet.
    --auth-key-file keeps it in a 0600 file that this state writes and removes. -#}
{%- if auth_key %}{% set up_args = up_args ~ ' --auth-key-file=' ~ authkey_path %}{% endif -%}
{%- set up_args = up_args ~ ' --accept-dns=' ~ ('true' if accept_dns else 'false') -%}
{%- if hostname %}{% set up_args = up_args ~ ' --hostname=' ~ hostname %}{% endif -%}
{%- if exit_node %}{% set up_args = up_args ~ ' --advertise-exit-node' %}{% endif -%}
{%- if routes %}{% set up_args = up_args ~ ' --advertise-routes=' ~ routes|join(',') %}{% endif -%}
{%- if accept_routes %}{% set up_args = up_args ~ ' --accept-routes' %}{% endif -%}
{%- if ssh_mode == 'tailscale' %}{% set up_args = up_args ~ ' --ssh' %}{% endif -%}

# Join, guarded on the persisted node state in BOTH modes (with or without an
# auth key). `tailscale up` re-run on an already-Running node is noisy and, with
# no auth key, re-initiates an interactive login every apply — so we skip it once
# the backend is Running. On first run / after key expiry it joins (with a key)
# or prints a registration URL you complete on Headscale (without a key). Role
# flags (routes/exit-node/dns/ssh) are NOT enforced here — see reconcile below.
{% if auth_key %}
# Written immediately before the join and removed immediately after, so the key
# is on disk for the shortest window that still lets tailscale read it.
"tailscale-authkey-file":
  file.managed:
    - name: {{ authkey_path }}
    - contents: {{ auth_key | yaml_encode }}
    - mode: '0600'
    - user: root
    - group: root
    - show_changes: False
    - require:
      - cmd: "tailscale-daemon-up"
{% endif %}

"tailscale-join":
  cmd.run:
    - name: tailscale up {{ up_args }}
    - runas: root
    - require:
      - cmd: "tailscale-daemon-up"
{%- if auth_key %}
      - file: "tailscale-authkey-file"
{%- endif %}
    - unless: tailscale status --json 2>/dev/null | grep -q '"BackendState":[[:space:]]*"Running"'

{% if auth_key %}
# Always removed, whether the join ran or was skipped by `unless`: a key left
# behind is a credential sitting in the qube long after it was needed.
"tailscale-authkey-file-remove":
  file.absent:
    - name: {{ authkey_path }}
    - require:
      - cmd: "tailscale-join"
{% endif %}

# Reconcile role flags on an already-joined node without re-running `up` (which
# would re-trigger login). `tailscale set` is a no-op when already at the desired
# value, so this enforces drift from config.jinja on every apply. Only runs once
# the backend is Running (otherwise there is nothing to set).
{%- set set_args = '--accept-dns=' ~ ('true' if accept_dns else 'false') -%}
{%- set set_args = set_args ~ ' --advertise-exit-node=' ~ ('true' if exit_node else 'false') -%}
{%- set set_args = set_args ~ ' --advertise-routes=' ~ (routes|join(',') if routes else '') -%}
{%- set set_args = set_args ~ ' --accept-routes=' ~ ('true' if accept_routes else 'false') -%}
{%- if hostname %}{% set set_args = set_args ~ ' --hostname=' ~ hostname %}{% endif -%}
{%- set set_args = set_args ~ ' --ssh=' ~ ('true' if ssh_mode == 'tailscale' else 'false') -%}
"tailscale-reconcile-flags":
  cmd.run:
    - name: tailscale set {{ set_args }}
    - runas: root
    - onlyif: tailscale status --json 2>/dev/null | grep -q '"BackendState":[[:space:]]*"Running"'
    - require:
      - cmd: "tailscale-join"

{% if routes or exit_node %}
"tailscale-routes-reminder":
  test.show_notification:
    - text: |
        mgmt.tailscale: this node advertises routes/exit-node. Approve them on
        your Headscale server, e.g.:
          headscale nodes list-routes
          headscale nodes approve-routes --identifier <NODE_ID> --routes {{ (routes + (['0.0.0.0/0','::/0'] if exit_node else []))|join(',') }}
    - require:
      - cmd: "tailscale-join"
{% endif %}

# --- 4. Optional plain sshd (key-only) so you can ssh into Qubes -------------
{% if ssh_mode == 'sshd' %}
"tailscale-ensure-sshd":
  cmd.run:
    - name: |
        if [ ! -x /usr/sbin/sshd ]; then
          apt-get update && apt-get install -y openssh-server
        fi
    - runas: root

"tailscale-authorized-keys":
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

"tailscale-sshd-config":
  file.managed:
    - name: /etc/ssh/sshd_config.d/10-tailscale.conf
    - mode: '0644'
    - makedirs: True
    - contents: |
        # SPDX-License-Identifier: MIT — mgmt.tailscale
        PasswordAuthentication no
        PermitRootLogin no
        PubkeyAuthentication yes
        X11Forwarding no
        AllowUsers user

"tailscale-rc-local":
  file.blockreplace:
    - name: /rw/config/rc.local
    - marker_start: "# >>> tailscale-sshd >>>"
    - marker_end: "# <<< tailscale-sshd <<<"
    - append_if_not_found: True
    - content: |
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true

"tailscale-rc-local-shebang":
  cmd.run:
    - name: |
        f=/rw/config/rc.local
        head -n1 "$f" | grep -q '^#!' || sed -i '1i #!/bin/sh' "$f"
        chmod 0755 "$f"
    - runas: root
    - require:
      - file: "tailscale-rc-local"

"tailscale-start-sshd-now":
  cmd.run:
    - name: systemctl restart ssh 2>/dev/null || systemctl restart sshd
    - runas: root
    - require:
      - cmd: "tailscale-ensure-sshd"
      - file: "tailscale-sshd-config"
      - file: "tailscale-authorized-keys"
{% endif %}

{% endif %}{# login_server present / empty #}

{% else %}

"tailscale-configure-disabled-note":
  test.show_notification:
    - text: |
        mgmt.tailscale.configure: cfg.tailscale.enabled is False — nothing to do.

{% endif %}{# enabled #}
{% endif %}{# not dom0 #}
