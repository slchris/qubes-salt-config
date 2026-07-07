{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Point a Debian template's apt sources at a mirror (layer 2). Runs INSIDE the
template. Reads cfg.mirror.debian_baseurl from config.jinja.

  sudo qubesctl --skip-dom0 --targets=debian-13-minimal state.apply mgmt.mirror.debian

Backs up sources to *.qbak on first change. Also mirrors security.debian.org to
<baseurl>-security (TUNA layout: /debian and /debian-security).
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set m = cfg.mirror -%}
{%- set enabled = m.get('enabled', False) -%}
{%- set url = m.get('debian_baseurl', '') -%}
{%- set sec_url = url ~ '-security' if url else '' -%}

{% if grains['nodename'] != 'dom0' and enabled and url %}

"mirror-debian-backup":
  cmd.run:
    - name: |
        for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list \
                 /etc/apt/sources.list.d/*.sources; do
          [ -f "$f" ] && [ ! -f "$f.qbak" ] && cp -a "$f" "$f.qbak"
        done; true

"mirror-debian-repoint":
  cmd.run:
    - name: |
        # security.debian.org first (more specific host), then the main mirror.
        sed -i -E 's#https?://security\.debian\.org(/debian-security)?#{{ sec_url }}#g' \
          /etc/apt/sources.list /etc/apt/sources.list.d/*.list \
          /etc/apt/sources.list.d/*.sources 2>/dev/null || true
        sed -i -E 's#https?://[a-z0-9.-]*deb\.debian\.org/debian#{{ url }}#g' \
          /etc/apt/sources.list /etc/apt/sources.list.d/*.list \
          /etc/apt/sources.list.d/*.sources 2>/dev/null || true
        apt-get update
    - require:
      - cmd: mirror-debian-backup
    - unless: grep -rqs "{{ url }}" /etc/apt/sources.list /etc/apt/sources.list.d/

{% endif %}
