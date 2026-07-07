{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Point dom0 repos at a mirror (dom0). Two layers:
  Layer 1 — template download source: /etc/qubes/repo-templates/*.repo
  Layer 3 — dom0 update source:        /etc/yum.repos.d/qubes-dom0.repo

Reads pillar qvm:mirror. Only runs when qvm:mirror:enabled is true and the
relevant baseurl is non-empty. Originals are backed up to *.qbak on first
change; comment metalink/mirrorlist out so the baseurl is used.

  sudo qubesctl state.apply mgmt.mirror.dom0

Revert by restoring the .qbak files (see README).
#}

{%- set m = salt['pillar.get']('qvm:mirror', {}) -%}
{%- set enabled = m.get('enabled', False) -%}
{%- set tmpl_url = m.get('templates_baseurl', '') -%}
{%- set dom0_url = m.get('dom0_baseurl', '') -%}

{% if grains['nodename'] == 'dom0' and enabled %}

{% if tmpl_url %}
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
          sed -i -E 's|^(\s*)(metalink\|mirrorlist)\s*=|\1#\2=|' "$f"
          sed -i -E 's#^(\s*baseurl\s*=\s*)https?://[^/]+(/.*)#\1{{ tmpl_url }}\2#' "$f"
        done
    - require:
      - cmd: mirror-templates-backup
    - unless: grep -rq "{{ tmpl_url }}" /etc/qubes/repo-templates/*.repo
{% endif %}

{% if dom0_url %}
# Layer 3: dom0 update source.
"mirror-dom0-backup":
  cmd.run:
    - name: "[ -f /etc/yum.repos.d/qubes-dom0.repo.qbak ] || cp -a /etc/yum.repos.d/qubes-dom0.repo /etc/yum.repos.d/qubes-dom0.repo.qbak"
    - onlyif: test -f /etc/yum.repos.d/qubes-dom0.repo

"mirror-dom0-repoint":
  cmd.run:
    - name: |
        sed -i -E 's|^(\s*)(metalink\|mirrorlist)\s*=|\1#\2=|' /etc/yum.repos.d/qubes-dom0.repo
        sed -i -E 's#^(\s*baseurl\s*=\s*)https?://[^/]+(/.*)#\1{{ dom0_url }}\2#' /etc/yum.repos.d/qubes-dom0.repo
    - require:
      - cmd: mirror-dom0-backup
    - unless: grep -q "{{ dom0_url }}" /etc/yum.repos.d/qubes-dom0.repo
{% endif %}

{% endif %}
