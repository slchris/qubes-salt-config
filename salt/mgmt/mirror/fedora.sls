{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Point a Fedora template's dnf repos at a mirror (layer 2). Runs INSIDE the
template. Reads cfg.mirror.fedora_baseurl from config.jinja.

  sudo qubesctl --skip-dom0 --targets=fedora-43-minimal state.apply mgmt.mirror.fedora

Uses dnf's config-manager to disable metalink and set a baseurl on the mirror,
keeping dnf's $releasever/$basearch variables so the repo tracks the template
version. Backs up the repo files to *.qbak on first change.
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set m = cfg.mirror -%}
{%- set enabled = m.get('enabled', False) -%}
{%- set url = m.get('fedora_baseurl', '') -%}

{% if grains['nodename'] != 'dom0' and enabled and url %}

"mirror-fedora-backup":
  cmd.run:
    - name: |
        for f in /etc/yum.repos.d/fedora.repo /etc/yum.repos.d/fedora-updates.repo; do
          [ -f "$f" ] && [ ! -f "$f.qbak" ] && cp -a "$f" "$f.qbak"
        done; true

"mirror-fedora-repoint":
  cmd.run:
    - name: |
        # Disable metalink/mirrorlist and set explicit baseurls on the mirror.
        sed -i -E 's|^(metalink\|mirrorlist)=|#&|' \
          /etc/yum.repos.d/fedora.repo /etc/yum.repos.d/fedora-updates.repo 2>/dev/null || true
        # fedora (releases) and updates paths on the mirror (TUNA-style layout).
        dnf config-manager --setopt=fedora.baseurl='{{ url }}/releases/$releasever/Everything/$basearch/os/' --save fedora 2>/dev/null || true
        dnf config-manager --setopt=updates.baseurl='{{ url }}/updates/$releasever/Everything/$basearch/' --save updates 2>/dev/null || true
        dnf clean all && dnf makecache || true
    - require:
      - cmd: mirror-fedora-backup
    - unless: grep -rqs "{{ url }}" /etc/yum.repos.d/fedora.repo

{% endif %}
