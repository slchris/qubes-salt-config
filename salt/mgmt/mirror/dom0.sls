{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Point dom0 repos at a mirror (dom0). Two layers:
  Layer 1 — template download source: /etc/qubes/repo-templates/*.repo
  Layer 3 — dom0 update source:        /etc/yum.repos.d/qubes-dom0.repo

Reads cfg.mirror from config.jinja. Only runs when qvm:mirror:enabled is true and the
relevant baseurl is non-empty. Originals are backed up to *.qbak on first
change; comment metalink/mirrorlist out so the baseurl is used.

  sudo qubesctl state.apply mgmt.mirror.dom0

Revert by restoring the .qbak files (see README).
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set m = cfg.mirror -%}
{%- set enabled = m.get('enabled', False) -%}
{%- set tmpl_url = m.get('templates_baseurl', '') -%}
{%- set dom0_url = m.get('dom0_baseurl', '') -%}

{% if grains['nodename'] == 'dom0' %}

{% if not enabled %}
# Mirror is disabled (pillar qvm:mirror:enabled is not true). Emit a visible
# no-op so `state.apply` reports success instead of "0 states run -> failed".
"mirror-dom0-disabled":
  test.succeed_without_changes:
    - name: "mgmt.mirror: mirror.enabled is false in config.jinja — nothing to do. Set it True and re-apply."
{% endif %}

{% if enabled and tmpl_url %}
# Layer 1: repoint every template repo's baseurl host+prefix, keep the path tail.
"mirror-templates-backup":
  cmd.run:
    - name: |
        for f in /etc/qubes/repo-templates/*.repo; do
          [ -f "$f.qbak" ] || cp -a "$f" "$f.qbak"
        done
    - onlyif: ls /etc/qubes/repo-templates/*.repo

"mirror-templates-repoint":
  cmd.run:
    - name: |
        for f in /etc/qubes/repo-templates/*.repo; do
          # Qubes ships metalink enabled and baseurl COMMENTED OUT. To use a
          # mirror we must: comment metalink, then UNCOMMENT the https baseurl
          # and repoint its host, keeping $releasever and the path tail. The
          # onion baseurl line is left commented.
          sed -i -E 's@^([[:space:]]*)(metalink|mirrorlist)[[:space:]]*=@\1#\2=@' "$f"
          sed -i -E 's@^#baseurl[[:space:]]*=[[:space:]]*https?://yum\.qubes-os\.org(/r\$releasever/[^ ]*)@baseurl = {{ tmpl_url }}\1@' "$f"
        done
    - require:
      - cmd: mirror-templates-backup
    - unless: grep -rq "^baseurl.*{{ tmpl_url }}" /etc/qubes/repo-templates/*.repo
{% endif %}

{% if enabled and dom0_url %}
# Layer 3: dom0 update source.
"mirror-dom0-backup":
  cmd.run:
    - name: "[ -f /etc/yum.repos.d/qubes-dom0.repo.qbak ] || cp -a /etc/yum.repos.d/qubes-dom0.repo /etc/yum.repos.d/qubes-dom0.repo.qbak"
    - onlyif: test -f /etc/yum.repos.d/qubes-dom0.repo

"mirror-dom0-repoint":
  cmd.run:
    - name: |
        f=/etc/yum.repos.d/qubes-dom0.repo
        sed -i -E 's@^([[:space:]]*)(metalink|mirrorlist)[[:space:]]*=@\1#\2=@' "$f"
        # Uncomment a commented https baseurl if present (same layout as the
        # template repo); also repoint an already-active baseurl if there is one.
        sed -i -E 's@^#baseurl[[:space:]]*=[[:space:]]*https?://yum\.qubes-os\.org(/r\$releasever/[^ ]*)@baseurl = {{ dom0_url }}\1@' "$f"
        sed -i -E 's@^(baseurl[[:space:]]*=[[:space:]]*)https?://yum\.qubes-os\.org@\1{{ dom0_url }}@' "$f"
    - require:
      - cmd: mirror-dom0-backup
    - unless: grep -q "^baseurl.*{{ dom0_url }}" /etc/yum.repos.d/qubes-dom0.repo
{% endif %}

{% endif %}
