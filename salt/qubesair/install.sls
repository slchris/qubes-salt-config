{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Install the console's runtime prerequisites (runs IN tpl-qubesair, NOT dom0 and
NOT the AppVM).

Installing in the TEMPLATE is mandatory in Qubes, not a style choice: an AppVM's
root volume is reset on every boot, so a terraform installed into the AppVM's
/usr/local/bin is gone after the first restart. Only /rw and /home survive
there, which is where the console's DATA lives (see qubesair.configure) — the
BINARIES live here.

debian-13-minimal ships none of this: terraform, sqlite3, curl and git are all
absent (measured on the target machine). The console does not embed terraform,
it execs it, so terraform is a hard prerequisite — without it every start/stop
fails at exec time with "executable file not found", AFTER the API call has
already reported success to the caller.

Deploy (from dom0):
  sudo qubesctl --skip-dom0 --targets=tpl-qubesair state.apply qubesair.install
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set qa = cfg.get('qubesair', {}) -%}
{%- set m = cfg.get('mirror', {}) -%}

{%- set tf_bin = qa.get('terraform_binary', '/usr/local/bin/terraform') -%}
{%- set tf_version = qa.get('terraform_version', '1.9.8') -%}
{%- set tf_url = qa.get('terraform_url',
      'https://releases.hashicorp.com/terraform/' ~ tf_version ~
      '/terraform_' ~ tf_version ~ '_linux_amd64.zip') -%}

{#- Known-good digests of the OFFICIAL terraform release zips (linux_amd64),
    taken from HashiCorp's own terraform_<v>_SHA256SUMS. They are a FALLBACK for
    when cfg.qubesair.terraform_sha256 is left empty — which it currently is —
    so that a stock deploy still verifies what it downloads instead of either
    failing or, far worse, installing an unchecked binary.

    cfg always wins when set, so pointing terraform_url at a mirror or at the
    LAN artifact store only requires pasting that copy's digest into
    config.jinja. Extend this map when bumping terraform_version:
      curl -s https://releases.hashicorp.com/terraform/<v>/terraform_<v>_SHA256SUMS | grep linux_amd64 -#}
{%- set tf_known_sha = {
      '1.9.8':  '186e0145f5e5f2eb97cbd785bc78f21bae4ef15119349f6ad4fa535b83b10df8',
      '1.15.8': 'd25ce7b6902013ad905db3d2eab0be4cd905887fe88b81a6171b8d5503c31f3d',
    } -%}
{%- set tf_sha = qa.get('terraform_sha256', '') or tf_known_sha.get(tf_version, '') -%}
{%- set tf_https = tf_url.startswith('https://') -%}

{#- Terraform provider mirror. The bpg/proxmox pin matches the version and the
    zip digest already recorded in qubes-air's terraform/.terraform.lock.hcl
    (the lock file's "zh:" hash for a provider IS the release zip's SHA256), so
    this digest is corroborated by a file the console repo already trusts rather
    than being a number typed in here. #}
{%- set mirror_dir = qa.get('terraform_mirror_dir', '/usr/share/terraform/providers') -%}
{%- set tfrc = qa.get('terraform_cli_config', '/etc/terraform/cli.tfrc') -%}
{%- set providers = qa.get('terraform_providers', [
      {'source': 'registry.terraform.io/bpg/proxmox',
       'version': '0.111.1',
       'url': 'https://github.com/bpg/terraform-provider-proxmox/releases/download/v0.111.1/terraform-provider-proxmox_0.111.1_linux_amd64.zip',
       'sha256': '6ed47bc00d0913a1d0880618fa1376115e9edab6b4a658c081061a7f0e4ca360'},
    ]) -%}

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
      # Fetching + verifying the terraform and provider archives below.
      - ca-certificates
      - curl
      - unzip
      # The console shells out to terraform, which uses git for module sources.
      - git
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
      # at all — and this template is built from debian-13-minimal. The old name
      # failed the whole pkg.installed state, which then took both dnsmasq states
      # down with it as unmet requisites: 5 failures whose visible cause was
      # "requisite failed", three steps away from the one package that was wrong.
      - bind9-dnsutils
      # SSH client only. The bpg/proxmox provider speaks SSH natively (Go), so
      # this is not a hard dependency of the provider — it is here because
      # uploading cloud-init snippets over SFTP to the PVE nodes is the most
      # fragile step in provisioning (bootstrap-design.md §4) and diagnosing it
      # from anywhere other than this qube reproduces none of the conditions.
      - openssh-client

{% if not tf_sha %}

# Refuse rather than install an unverified binary. This mirrors what the console
# itself does with the agent package: a URL with no digest is rejected at
# startup on purpose. terraform is handed the PVE API token and drives the whole
# cluster, so an unpinned download is a straight path from "anyone on the
# network path" to "root on every remote qube".
"qubesair-terraform-digest-required":
  test.fail_without_changes:
    - name: |
        cfg.qubesair.terraform_sha256 is empty and this state has no built-in
        digest for terraform {{ tf_version }}, so the download cannot be
        verified and terraform was NOT installed.

        Fix by pasting the digest into salt/config.jinja:
          curl -s https://releases.hashicorp.com/terraform/{{ tf_version }}/terraform_{{ tf_version }}_SHA256SUMS \
            | grep linux_amd64
        or pin a version this state already knows: {{ tf_known_sha.keys() | join(', ') }}.
    - failhard: True

{% elif tf_version not in tf_url %}

# Fails closed anyway (the digest would not match), but the bare
# "sha256sum: WARNING: 1 computed checksum did NOT match" that produces sends
# people hunting for a compromised mirror instead of a stale URL.
"qubesair-terraform-version-url-mismatch":
  test.fail_without_changes:
    - name: |
        cfg.qubesair.terraform_version is {{ tf_version }} but terraform_url
        does not mention that version:
          {{ tf_url }}
        The digest is selected by VERSION, so these must agree. Update both.
    - failhard: True

{% else %}

# Download, VERIFY, then install — in that order, in one shell so a failed
# verification can never be followed by an install. The archive is unpacked into
# a temp dir that the trap removes, so a rejected binary is not left behind for
# someone to "just chmod +x" later.
#
# Source: the pinned release zip from releases.hashicorp.com, checked against a
# digest that travels with this repo. Chosen over the two alternatives:
#
#   - HashiCorp's apt repo (apt.releases.hashicorp.com) is GPG-signed, but it
#     FLOATS: `apt-get install terraform` gives whatever is newest that day, so
#     two templates built a week apart run different terraform against the same
#     cluster and nothing records which. It also has no CN mirror — this repo
#     already dropped VS Code from templates.dev.install for exactly that
#     failure (packages.microsoft.com unreachable often enough to break the
#     whole install), and apt.releases.hashicorp.com is the same shape of bet.
#
#   - The LAN artifact store at 10.31.0.2 is fast and always reachable, but it
#     serves over plain HTTP with no TLS and no signature (bootstrap-design.md
#     §6.4). That is ACCEPTABLE — but only because the digest travels a
#     different, trusted channel (this repo -> scripts/setup.sh -> dom0
#     /srv/salt) than the bytes do, which is the same argument that makes the
#     agent .deb safe. It is not preferable, because it adds a publish step
#     whose failure mode is a stale binary served under the right name. Point
#     terraform_url there when the upstream link is unusable; the digest check
#     below is unchanged and becomes the ONLY thing standing between the LAN
#     and root on the cluster.
"qubesair-terraform-install":
  cmd.run:
    - name: |
        set -eu
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT
        # A TemplateVM has NO netvm. Its only route out is the Qubes update
        # proxy, which qubes-core-agent-networking exports via /etc/profile.d —
        # and salt does not source profile scripts, so an unqualified curl here
        # just hangs until it times out. Sourced rather than hardcoded so this
        # keeps working if Qubes moves the proxy address.
        if [ -z "${https_proxy:-}${HTTPS_PROXY:-}" ] && [ -r /etc/profile.d/qubes-proxy.sh ]; then
          . /etc/profile.d/qubes-proxy.sh
        fi
        curl -fsSL {% if tf_https %}--proto '=https' --tlsv1.2 {% endif %}-o "$tmp/terraform.zip" '{{ tf_url }}'
        echo '{{ tf_sha }}  '"$tmp/terraform.zip" | sha256sum -c -
        unzip -q -o "$tmp/terraform.zip" -d "$tmp"
        install -D -m 0755 -o root -g root "$tmp/terraform" '{{ tf_bin }}'
    - runas: root
    - require:
      - pkg: qubesair-packages
    {#- Pins DOWNWARD as well as upward: a terraform that is not exactly the
        configured version is replaced, so an ad-hoc upgrade inside the template
        does not silently become the version driving the cluster. #}
    - unless: test -x '{{ tf_bin }}' && '{{ tf_bin }}' version | head -n1 | grep -qx 'Terraform v{{ tf_version }}'

{% endif %}

# --- Provider mirror ---------------------------------------------------------
# `terraform init` reaches out to registry.terraform.io on every run. Seeding a
# filesystem mirror makes the provider that actually matters here — bpg/proxmox,
# the one holding the PVE token — come from a byte-for-byte pinned copy instead
# of whatever the registry serves at apply time, and lets init work when the
# registry is slow or blocked from this network.
{% for p in providers %}
{%- set parts = p.get('source', '').split('/') %}
{%- if parts | length == 3 %}
{%- set p_host = parts[0] %}
{%- set p_ns = parts[1] %}
{%- set p_type = parts[2] %}
{%- set p_zip = mirror_dir ~ '/' ~ p_host ~ '/' ~ p_ns ~ '/' ~ p_type ~ '/terraform-provider-' ~ p_type ~ '_' ~ p.version ~ '_linux_amd64.zip' %}

{% if p.get('sha256', '') %}
# "packed" filesystem_mirror layout: terraform expects the release zip itself,
# named exactly as the registry names it, under <host>/<namespace>/<type>/.
"qubesair-provider-{{ p_type }}":
  cmd.run:
    - name: |
        set -eu
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT
        if [ -z "${https_proxy:-}${HTTPS_PROXY:-}" ] && [ -r /etc/profile.d/qubes-proxy.sh ]; then
          . /etc/profile.d/qubes-proxy.sh
        fi
        curl -fsSL -o "$tmp/provider.zip" '{{ p.url }}'
        echo '{{ p.sha256 }}  '"$tmp/provider.zip" | sha256sum -c -
        install -D -m 0644 -o root -g root "$tmp/provider.zip" '{{ p_zip }}'
    - runas: root
    - require:
      - pkg: qubesair-packages
    - unless: |
        set -eu
        test -f '{{ p_zip }}' || exit 1
        echo '{{ p.sha256 }}  {{ p_zip }}' | sha256sum -c - >/dev/null 2>&1
{% else %}
"qubesair-provider-{{ p_type }}-digest-required":
  test.fail_without_changes:
    - name: |
        Provider {{ p.source }} {{ p.version }} has no sha256 in
        cfg.qubesair.terraform_providers — not mirrored. A provider runs with
        the PVE credentials; it is not installed unverified.
    - failhard: True
{% endif %}
{%- endif %}
{% endfor %}

# Only the mirrored providers are pinned to the mirror; everything else still
# resolves from the registry, so this does not silently break `terraform init`
# for a provider nobody remembered to mirror (qubes-air's terraform/main.tf also
# declares hashicorp/google and hashicorp/aws — see this module's README).
"qubesair-terraform-cli-config":
  file.managed:
    - name: {{ tfrc }}
    - makedirs: True
    - mode: '0644'
    - user: root
    - group: root
    - contents: |
        # SPDX-License-Identifier: MIT — managed by qubesair.install
        provider_installation {
          filesystem_mirror {
            path    = "{{ mirror_dir }}"
            include = [
        {%- for p in providers %}
              "{{ p.source }}",
        {%- endfor %}
            ]
          }
          direct {
            exclude = [
        {%- for p in providers %}
              "{{ p.source }}",
        {%- endfor %}
            ]
          }
        }

# terraform has no system-wide config path on Linux — it reads $HOME/.terraformrc
# or $TF_CLI_CONFIG_FILE and nothing else. /root/.terraformrc is on the root
# volume, so shipping the symlink in the TEMPLATE is what makes it survive the
# AppVM's reboot reset. The `user` case is handled in qubesair.configure, since
# /home is the private volume and the template cannot reach it.
"qubesair-terraform-root-rc":
  file.symlink:
    - name: /root/.terraformrc
    - target: {{ tfrc }}
    - force: True
    - require:
      - file: qubesair-terraform-cli-config

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
