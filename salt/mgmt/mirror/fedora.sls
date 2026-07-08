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
        # CONSERVATIVE: only switch a repo to the mirror if the mirror path is
        # actually reachable; otherwise leave the official metalink untouched.
        # Never disable metalink without a working baseurl — that leaves a repo
        # with no source at all (the exact breakage this replaces).
        REL="$(rpm -E %fedora)"
        ARCH="$(rpm -E %_arch)"
        BASE_REL="{{ url }}/releases/${REL}/Everything/${ARCH}/os"
        BASE_UPD="{{ url }}/updates/${REL}/Everything/${ARCH}"
        # Fedora N pre-release lives under development/, not releases/ — try both.
        DEV_REL="{{ url }}/development/${REL}/Everything/${ARCH}/os"

        reachable() { curl -sf -o /dev/null --max-time 20 "$1/repodata/repomd.xml"; }

        set_repo() {  # $1=repo-file  $2=section  $3=baseurl
          local f="$1" sec="$2" url="$3"
          # comment metalink/mirrorlist ONLY inside this section, then add baseurl
          awk -v sec="[$sec]" -v burl="$url" '
            $0==sec {print; insec=1; print "baseurl=" burl; next}
            /^\[/ && $0!=sec {insec=0}
            insec && /^(metalink|mirrorlist)=/ {print "#" $0; next}
            insec && /^baseurl=/ {next}
            {print}
          ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
        }

        # releases repo: try releases/ then development/
        if reachable "$BASE_REL"; then
          set_repo /etc/yum.repos.d/fedora.repo fedora "$BASE_REL"
          echo "fedora repo -> $BASE_REL"
        elif reachable "$DEV_REL"; then
          set_repo /etc/yum.repos.d/fedora.repo fedora "$DEV_REL"
          echo "fedora repo -> $DEV_REL (development)"
        else
          echo "fedora: mirror path not reachable, keeping official metalink"
        fi

        # updates repo
        if reachable "$BASE_UPD"; then
          set_repo /etc/yum.repos.d/fedora-updates.repo updates "$BASE_UPD"
          echo "updates repo -> $BASE_UPD"
        else
          echo "updates: mirror path not reachable, keeping official metalink"
        fi

        dnf clean all && dnf makecache || true
    - require:
      - cmd: mirror-fedora-backup
    - unless: grep -rqs "^baseurl={{ url }}" /etc/yum.repos.d/fedora.repo /etc/yum.repos.d/fedora-updates.repo

{% endif %}
