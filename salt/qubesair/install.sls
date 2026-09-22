{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Install the console's runtime prerequisites (runs IN tpl-qubesair, NOT dom0 and
NOT the AppVM).

Installing in the TEMPLATE is mandatory in Qubes, not a style choice: an AppVM's
root volume is reset on every boot, so a binary installed into the AppVM's /usr
is gone after the first restart. Only /rw and /home survive there, which is
where the console's DATA lives (see qubesair.configure) — the BINARIES live
here.

NOT in /usr/local, though. An AppVM mounts its private volume's usrlocal
subdirectory over /usr/local (`findmnt /usr/local` in a running AppVM shows
/dev/xvdb[/usrlocal]), which completely masks whatever the template has there.
Template-wide binaries belong on the root volume: /usr/bin.

debian-13-minimal ships none of this: the console's runtime dependencies
(sqlite3, dnsmasq, dig, an SSH client) are all absent (measured on the target
machine). The console is a self-contained binary: it drives provider APIs with
Go's own HTTP/TLS stack and does no exec of terraform or any other tool.

Deploy (from dom0):
  sudo qubesctl --skip-dom0 --targets=tpl-qubesair state.apply qubesair.install
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set qa = cfg.get('qubesair', {}) -%}
{%- set m = cfg.get('mirror', {}) -%}

{% if grains['nodename'] != 'dom0' %}
{% if qa.get('enabled', False) %}

{# Guard exactly like mgmt.mirror.debian declares its state: enabled AND a
   non-empty debian_baseurl. Guarding on enabled alone would emit a require on
   `mirror-debian-repoint` that does not exist when the URL is blank, aborting
   the whole run with a dangling-requisite error. #}
{% if m.get('enabled', False) and m.get('debian_baseurl', '') %}
include:
  - mgmt.mirror.debian
{% endif %}

"qubesair-update":
  pkg.uptodate:
    - refresh: True
{% if m.get('enabled', False) and m.get('debian_baseurl', '') %}
    - require:
      - cmd: mirror-debian-repoint
{% endif %}

# Deliberately short. Every package here is reachable from a qube holding the
# PVE token and the agent CA key, so the list is the console's prerequisites and
# nothing more — no editors, no build toolchain, no language runtimes.
#
# NOTE what is NOT here: openssh-SERVER. The whole reason this qube exists
# instead of reusing mgmt-jump is that mgmt-jump accepts inbound SSH, and a
# qube anyone on the LAN can knock on must not also hold the credentials that
# can rebuild the fleet. Installing it here re-creates exactly that problem.
"qubesair-packages":
  pkg.installed:
    - require:
      - pkg: qubesair-update
    - pkgs:
      # A minimal template has no networking at all without this.
      - qubes-core-agent-networking
      # Without it there is no root in the qube: debian-13-minimal sets no root
      # password, so with no passwordless sudo an operator cannot get root even
      # to read a log. It does not weaken the boundary that matters here — the
      # user account can already read the console's data directory.
      - qubes-core-agent-passwordless-root
      # The console verifies the PVE API's TLS certificate with the system CA
      # pool; a minimal template may not ship it.
      - ca-certificates
      # The console links its own SQLite driver; this is the operator's only way
      # to inspect the database when the API is the thing being debugged.
      - sqlite3
      # Split-horizon resolver for pve.infra.plz.ac — see qubesair.configure.
      - dnsmasq
      # dig. Used by the DNS setup script to prove dnsmasq is actually ANSWERING
      # before /etc/resolv.conf is repointed at it. Without a query tool the
      # script cannot tell "dnsmasq is up" from "dnsmasq died on a bad config",
      # and repointing resolv.conf blindly turns a DNS misconfiguration into a
      # qube with no DNS at all.
      #
      # bind9-dnsutils, not dnsutils: the transitional `dnsutils` package is gone
      # in Debian 13 (trixie) — `apt-cache policy dnsutils` reports no candidate
      # at all — and this template is built from debian-13-minimal.
      - bind9-dnsutils
      # SSH client only. Uploading the cloud-init snippet writes
      # /var/lib/vz/snippets/ on the node over SSH and the PVE API has no
      # endpoint for it (still true in PVE 9.2), so the console needs an SSH
      # client to provision.
      - openssh-client

# Bind dnsmasq to loopback from the very first second of boot. Debian's default
# listens on every interface: qubesair.configure only rewrites the resolver
# config once rc.local runs, which leaves a window where this qube is an open
# resolver on its network-facing interface. Qubes' default-deny input chain
# makes that unreachable in practice — this closes it in the qube itself rather
# than relying on a firewall rule that a later state could relax.
"qubesair-dnsmasq-base":
  file.managed:
    - name: /etc/dnsmasq.d/00-qubesair-base.conf
    - makedirs: True
    - mode: '0644'
    - user: root
    - group: root
    - contents: |
        # SPDX-License-Identifier: MIT — managed by qubesair.install
        listen-address=127.0.0.1
        bind-interfaces
    - require:
      - pkg: qubesair-packages

# Enable the unit HERE, in the template. `systemctl enable` writes into
# /etc/systemd/system, which is on the root volume — doing it in the AppVM
# would work until the next reboot and then quietly stop. Debian's postinst
# already enables dnsmasq; this makes the console's DNS independent of that
# staying true across package versions.
"qubesair-dnsmasq-enable":
  cmd.run:
    - name: systemctl enable dnsmasq
    - runas: root
    - unless: systemctl is-enabled dnsmasq
    - require:
      - file: qubesair-dnsmasq-base

{% else %}

"qubesair-install-disabled-note":
  test.show_notification:
    - text: |
        qubesair.install: cfg.qubesair.enabled is False — nothing installed.

{% endif %}
{% endif %}
