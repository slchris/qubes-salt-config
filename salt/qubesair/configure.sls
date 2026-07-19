{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Configure the console AppVM's NETWORKING (runs IN qubesair-console, not dom0).

Scope note: the console SERVICE — its binary, unit, env files, secrets and data
layout — belongs to qubesair.console, not here. This state deliberately declares
no directory that state also declares: two file.directory states on one path
with different modes flip it back and forth on every apply, and the resulting
"changed" report trains people to ignore the one that matters. Everything below
lives under /rw/config/qubesair-net/, which nothing else touches.

What is left here is the qube-level problem: DNS. The console must resolve
pve.infra.plz.ac, and Qubes' default forwarders (10.139.1.1/.2) do not — only
the internal resolver 10.31.0.252 does. The tempting fix, pointing pve_endpoint
at 10.31.0.253 directly, throws away hostname validation of a valid Let's
Encrypt certificate on the one connection that carries the PVE API token, so the
name has to keep working.

Why a local dnsmasq rather than just writing the resolver into resolv.conf:
resolv.conf can only express "ask these servers, in order", not "ask THIS server
for THAT zone". Handing every query to 10.31.0.252 makes the console's public
DNS (registry.terraform.io for `terraform init`, among others) depend on an
internal resolver recursing for the whole internet — and if it does not, it
answers NXDOMAIN, which glibc treats as a real answer and never retries against
the next nameserver. Split-horizon forwarding keeps internal names internal and
everything else on the path Qubes already set up.

Prereqs: qubesair.install applied to the template (it provides dnsmasq and dig),
and the qube created by qubesair.create and started.

Deploy (from dom0):
  sudo qubesctl --skip-dom0 --targets=qubesair-console state.apply qubesair.configure
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set qa = cfg.get('qubesair', {}) -%}

{#- Owned solely by this state. NOT cfg.qubesair.data_dir and NOT config_dir:
    both of those are the console service's, and sharing a directory across two
    states that each think they set its mode is how a 0700 secrets directory
    quietly becomes 0755. #}
{%- set net_dir = qa.get('net_dir', '/rw/config/qubesair-net') -%}
{%- set tfrc = qa.get('terraform_cli_config', '/etc/terraform/cli.tfrc') -%}

{#- Which names go to the internal resolver. Derived from pve_endpoint by
    default — both the exact host and its parent zone — so that changing the
    endpoint does not leave a stale zone list behind pointing DNS at nothing.
    The exact host is listed as well as the parent because it is the one name
    that MUST resolve, and it keeps working even if the parent-zone guess is
    wrong for some future endpoint. Override with cfg.qubesair.dns_domains. #}
{%- set pve_host = qa.get('pve_endpoint', '').split('://')[-1].split('/')[0].split(':')[0] -%}
{%- set pve_is_ip = pve_host.replace('.', '').isdigit() -%}
{%- set pve_parent = pve_host.split('.', 1)[1] if '.' in pve_host else '' -%}
{%- set derived = (pve_host ~ ' ' ~ pve_parent) if (pve_host and not pve_is_ip and '.' in pve_parent) else '' -%}
{%- set domains = (qa.get('dns_domains', []) | join(' ')) or derived -%}
{%- set internal_dns = qa.get('dns', '') -%}

{% if grains['nodename'] != 'dom0' %}
{% if qa.get('enabled', False) %}

# --- 1. This state's own directory ------------------------------------------
# Root-owned: the script it holds runs from rc.local as root and rewrites
# /etc/resolv.conf, so it must not be writable by anything that is not already
# root. Contains no secrets, hence 0755 rather than 0700.
"qubesair-net-dir":
  file.directory:
    - name: {{ net_dir }}
    - user: root
    - group: root
    - mode: '0755'
    - makedirs: True

# terraform reads $HOME/.terraformrc or $TF_CLI_CONFIG_FILE and nothing else.
# The template ships /root/.terraformrc; /home is the private volume, which the
# template cannot reach, so the `user` case is covered here. This is for
# INTERACTIVE use — the console service runs with its own HOME and ProtectHome=yes
# (see qubesair.console), so it needs TF_CLI_CONFIG_FILE set in its unit
# instead; without that the service ignores the seeded provider mirror and goes
# to the registry, which merely makes `terraform init` slower until the day the
# registry is unreachable from this network and it fails outright.
"qubesair-user-terraformrc":
  file.symlink:
    - name: /home/user/.terraformrc
    - target: {{ tfrc }}
    - user: user
    - group: user
    - force: True

# --- 2. Split-horizon DNS ----------------------------------------------------
{% if not internal_dns %}

"qubesair-dns-not-configured":
  test.show_notification:
    - text: |
        qubesair.configure: cfg.qubesair.dns is empty — DNS left as Qubes
        configured it. pve.infra.plz.ac will NOT resolve and every PVE call
        will fail name resolution.

{% elif not domains %}

"qubesair-dns-no-domains":
  test.fail_without_changes:
    - name: |
        cfg.qubesair.dns is set ({{ internal_dns }}) but no internal zone could
        be derived from pve_endpoint ({{ qa.get('pve_endpoint', '') }}) and
        cfg.qubesair.dns_domains is empty.

        Forwarding EVERY query to the internal resolver is not done implicitly
        here: if it does not recurse for public names it answers NXDOMAIN, glibc
        accepts that as an answer, and public DNS breaks in a way that looks
        like a network fault. Set qubesair.dns_domains explicitly.
    - failhard: True

{% else %}

# The whole DNS setup is one script rather than a pile of rc.local lines,
# because it has to run identically at boot and on a salt re-apply, and because
# the decision it makes — whether it is SAFE to repoint resolv.conf — needs real
# control flow.
"qubesair-dns-script":
  file.managed:
    - name: {{ net_dir }}/setup-dns.sh
    - makedirs: True
    - mode: '0700'
    - user: root
    - group: root
    - contents: |
        #!/bin/sh
        # SPDX-License-Identifier: MIT — managed by qubesair.configure
        #
        # Split-horizon DNS for the Qubes Air console.
        #   {{ domains }}  ->  {{ internal_dns }}   (internal resolver)
        #   everything else ->  whatever Qubes gave this qube
        #
        # Must re-run every boot: Qubes regenerates /etc/resolv.conf from the
        # netvm's QubesDB entries, and /etc lives on the root volume, which is
        # reset. Nothing here is edited once and expected to stay.
        set -eu

        RESOLV=/etc/resolv.conf
        CONF=/etc/dnsmasq.d/10-qubesair.conf
        CACHE={{ net_dir }}/upstream-dns
        INTERNAL_DNS='{{ internal_dns }}'
        DOMAINS='{{ domains }}'

        # Take the upstreams Qubes just configured rather than hardcoding
        # 10.139.1.1/.2. Those addresses are the netvm's business, not ours, and
        # a frozen copy would break silently the day they change.
        upstream=$(awk '$1 == "nameserver" && $2 != "127.0.0.1" { print $2 }' "$RESOLV" 2>/dev/null || true)

        # On a re-apply (as opposed to a boot) resolv.conf ALREADY points at
        # 127.0.0.1 from the previous run, so there is nothing to read. Without
        # this cache the script would find no upstreams, bail out, and quietly
        # stop refreshing the config it is supposed to own.
        if [ -n "$upstream" ]; then
            printf '%s\n' $upstream > "$CACHE"
        elif [ -r "$CACHE" ]; then
            upstream=$(cat "$CACHE")
        fi

        if [ -z "$upstream" ]; then
            echo "no upstream nameserver found in $RESOLV or $CACHE - leaving DNS untouched"
            exit 0
        fi

        umask 022
        {
            echo "# generated by {{ net_dir }}/setup-dns.sh - do not edit"
            # no-resolv is load-bearing, not tidiness: without it dnsmasq reads
            # /etc/resolv.conf for its upstreams, and this script is about to
            # point that file at dnsmasq itself. That is a query loop, and the
            # symptom is every lookup in the qube timing out.
            echo "no-resolv"
            echo "cache-size=1000"
            for d in $DOMAINS; do
                [ -n "$d" ] || continue
                echo "server=/$d/$INTERNAL_DNS"
            done
            for u in $upstream; do
                echo "server=$u"
            done
        } > "$CONF.tmp"
        mv "$CONF.tmp" "$CONF"

        systemctl restart dnsmasq

        # Prove dnsmasq ANSWERS before handing it the qube's resolution. dig
        # exits non-zero only when it got no reply at all, which is exactly the
        # condition that matters: NXDOMAIN is a working resolver.
        probe=$(echo $DOMAINS | awk '{ print $1 }')
        ok=0
        i=0
        while [ "$i" -lt 10 ]; do
            if dig +time=1 +tries=1 "@127.0.0.1" "$probe" > /dev/null 2>&1; then
                ok=1
                break
            fi
            i=$((i + 1))
            sleep 1
        done

        if [ "$ok" -ne 1 ]; then
            echo "dnsmasq not answering on 127.0.0.1 - leaving $RESOLV on $upstream"
            exit 1
        fi

        # 127.0.0.1 ONLY. Keeping the original servers as a "fallback" would not
        # be one: glibc walks the list in order and stops at the first ANSWER,
        # and an upstream that does not know infra.plz.ac answers NXDOMAIN.
        # A dnsmasq hiccup would therefore not fail over, it would silently
        # start returning "no such host" for the PVE endpoint.
        printf 'nameserver 127.0.0.1\n' > "$RESOLV.tmp"
        mv "$RESOLV.tmp" "$RESOLV"

        # Advisory: report whether the internal zone actually resolves. Not
        # fatal — the qube is still usable and DNS is now correctly wired; this
        # is the line that tells you the internal resolver, not this qube, is
        # the thing that is wrong.
        answer=$(dig +short +time=2 +tries=1 "$probe" 2>/dev/null || true)
        if [ -n "$answer" ]; then
            echo "$probe -> $answer (via $INTERNAL_DNS)"
        else
            echo "WARNING: $probe did not resolve via $INTERNAL_DNS"
        fi

# Re-run on every boot. Marker-merged into the shared rc.local so it coexists
# with any other module's block, same convention as mgmt.tailscale.
"qubesair-dns-rc-local":
  file.blockreplace:
    - name: /rw/config/rc.local
    - marker_start: "# >>> qubesair-dns >>>"
    - marker_end: "# <<< qubesair-dns <<<"
    - append_if_not_found: True
    - show_changes: True
    - content: |
        # Managed by qubesair.configure — do not edit between markers.
        if [ -x {{ net_dir }}/setup-dns.sh ]; then
            {{ net_dir }}/setup-dns.sh 2>&1 | logger -t qubesair-dns
        fi
    - require:
      - file: qubesair-dns-script

"qubesair-dns-rc-shebang":
  cmd.run:
    - name: |
        f=/rw/config/rc.local
        head -n1 "$f" | grep -q '^#!' || sed -i '1i #!/bin/sh' "$f"
        chmod 0755 "$f"
    - runas: root
    - require:
      - file: qubesair-dns-rc-local

# Apply now as well. rc.local already ran for this boot, so without this the
# console would not have working DNS until the next restart — and the first
# thing anyone does after applying this state is try to reach PVE.
"qubesair-dns-apply-now":
  cmd.run:
    - name: {{ net_dir }}/setup-dns.sh
    - runas: root
    - require:
      - cmd: qubesair-dns-rc-shebang

{% endif %}

{% else %}

"qubesair-configure-disabled-note":
  test.show_notification:
    - text: |
        qubesair.configure: cfg.qubesair.enabled is False — nothing to do.

{% endif %}
{% endif %}
