{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Install tailscaled in the TEMPLATE (runs IN the template, default
debian-13-minimal). Installing in the template — not the AppVM — is mandatory in
Qubes: the AppVM root volume is reset every boot, so a per-AppVM install would
vanish. The daemon binary lives in the template; only mutable state
(/var/lib/tailscale) is persisted per-AppVM via bind-dirs (mgmt.tailscale.configure).

Package source: the official Tailscale apt repo (pkgs.tailscale.com), fetched
through the Qubes update-proxy that minimal templates already use. On a
China-network host the mirror layer (mgmt.mirror.debian) repoints Debian's own
sources; Tailscale's repo has no CN mirror, so it goes out via the update-proxy.

We also pre-create /var/lib/tailscale and stop the daemon here so the template
doesn't ship a running/authenticated tailscaled (the AppVM starts it).

Deploy (from dom0):
  sudo qubesctl --skip-dom0 --targets=debian-13-minimal state.apply mgmt.tailscale.install
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set ts = cfg.get('tailscale', {}) -%}
{%- set m = cfg.get('mirror', {}) -%}

{% if grains['nodename'] != 'dom0' %}

{# Guard exactly like mgmt.mirror.debian declares its state: enabled AND a
   non-empty debian_baseurl. Guarding on enabled alone would emit a require on
   `mirror-debian-repoint` that does not exist when the URL is blank, aborting
   the whole run with a dangling-requisite error. #}
{% if m.get('enabled', False) and m.get('debian_baseurl', '') %}
# Repoint Debian's own apt sources at the CN mirror first (Tailscale's repo is
# not mirrored — it still goes out via the Qubes update-proxy).
include:
  - mgmt.mirror.debian
{% endif %}

# Tailscale's signing key + apt source. Debian 13 = trixie. keyrings/sources are
# placed the modern (deb822-free) way to match Tailscale's documented install.
"tailscale-apt-keyring":
  cmd.run:
    - name: |
        set -e
        install -d -m 0755 /usr/share/keyrings
        if [ ! -s /usr/share/keyrings/tailscale-archive-keyring.gpg ]; then
          curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg \
            -o /usr/share/keyrings/tailscale-archive-keyring.gpg
        fi
    - runas: root
    - unless: test -s /usr/share/keyrings/tailscale-archive-keyring.gpg

"tailscale-apt-source":
  file.managed:
    - name: /etc/apt/sources.list.d/tailscale.list
    - mode: '0644'
    - user: root
    - group: root
    - contents: |
        # SPDX-License-Identifier: MIT — managed by mgmt.tailscale.install
        deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/debian trixie main
    - require:
      - cmd: "tailscale-apt-keyring"

"tailscale-apt-update":
  cmd.run:
    - name: apt-get update
    - runas: root
    - require:
      - file: "tailscale-apt-source"
{% if m.get('enabled', False) and m.get('debian_baseurl', '') %}
      - cmd: mirror-debian-repoint
{% endif %}

"tailscale-packages":
  pkg.installed:
    - pkgs:
      # tailscale pulls tailscaled; qubes-core-agent-networking makes a minimal
      # template behave as a NetVM.
      - tailscale
      - qubes-core-agent-networking
      - nftables
      - curl
      # Local DNS forwarder: downstream AppVMs' :53 is REDIRECT'd to this box,
      # dnsmasq forwards to MagicDNS 100.100.100.100 (see mgmt.tailscale.configure).
      - dnsmasq
    - require:
      - cmd: "tailscale-apt-update"

# Pre-create the state dir in the template so the AppVM's bind-dirs mount lands
# on an existing path (bind-dirs won't mount over a missing target cleanly).
"tailscale-state-dir":
  file.directory:
    - name: /var/lib/tailscale
    - mode: '0700'
    - user: root
    - group: root
    - require:
      - pkg: "tailscale-packages"

# Enable IP forwarding so the qube can act as a subnet router / exit node once
# built from this template.
"tailscale-ip-forward":
  file.managed:
    - name: /etc/sysctl.d/99-tailscale-forward.conf
    - mode: '0644'
    - contents: |
        net.ipv4.ip_forward = 1
        net.ipv6.conf.all.forwarding = 1
    - require:
      - pkg: "tailscale-packages"

# Don't ship a running/authenticated daemon in the template — the AppVM starts
# it (mgmt.tailscale.configure). We keep the unit enabled so the AppVM's
# systemd brings it up on boot, but it must not be running *now* in the template.
# Same for dnsmasq: Debian enables+starts it on install; leave the unit disabled
# in the template (the AppVM enables/restarts it with our drop-in via rc.local)
# so it doesn't fight resolved or occupy :53 in every qube built from this tpl.
"tailscale-template-stop":
  cmd.run:
    - name: |
        systemctl stop tailscaled 2>/dev/null || true
        systemctl disable --now dnsmasq 2>/dev/null || true
    - runas: root
    - require:
      - pkg: "tailscale-packages"

{% endif %}
