#!/bin/bash
# SPDX-FileCopyrightText: 2026 Chris Su
# SPDX-License-Identifier: MIT
#
# Configure (or revert) Qubes OS download mirrors — OPT-IN.
#
# Run in DOM0. Useful when the default ITL/upstream sources are slow or
# unreachable. Every change backs up the original file next to it (*.qbak) and
# is reversible with --disable.
#
# Three independent layers (enable only what you need):
#   1. templates  : Qubes template download source (dom0)
#                   /etc/qubes/repo-templates/*.repo
#   2. dom0       : Qubes dom0 package update source (dom0)
#                   /etc/yum.repos.d/qubes-dom0.repo
#   3. in-template: OS package source INSIDE a template (apt/dnf). This cannot
#                   be done from dom0 — the script prints the exact commands to
#                   run inside the template instead.
#
# Usage:
#   sudo ./scripts/qubes-mirror.sh --templates-url URL
#   sudo ./scripts/qubes-mirror.sh --dom0-url URL
#   sudo ./scripts/qubes-mirror.sh --templates-url URL --dom0-url URL
#   sudo ./scripts/qubes-mirror.sh --debian-url URL     # prints in-template steps
#   sudo ./scripts/qubes-mirror.sh --fedora-url URL     # prints in-template steps
#   sudo ./scripts/qubes-mirror.sh --disable            # restore all *.qbak
#   sudo ./scripts/qubes-mirror.sh --dry-run --templates-url URL
#
# The URLs are your choice. This script itself ships no default; the recommended
# default (Tsinghua TUNA, mirrors.tuna.tsinghua.edu.cn/qubesos/repo/yum, verified
# to carry the Qubes r4.3 repos; kernel.org for outside China) lives in
# pillar/user.sls under qvm:mirror. See docs/mirror.md.

set -eu

DRY_RUN=0
DISABLE=0
TEMPLATES_URL=""
DOM0_URL=""
DEBIAN_URL=""
FEDORA_URL=""

REPO_TEMPLATES="/etc/qubes/repo-templates"
DOM0_REPO="/etc/yum.repos.d/qubes-dom0.repo"

info()  { echo "==> $1"; }
warn()  { echo "warning: $1" >&2; }
die()   { echo "error: $1" >&2; exit 1; }

usage() {
    sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)        usage; exit 0 ;;
        -n|--dry-run)     DRY_RUN=1; shift ;;
        --disable)        DISABLE=1; shift ;;
        --templates-url)  TEMPLATES_URL="${2:?--templates-url needs a URL}"; shift 2 ;;
        --dom0-url)       DOM0_URL="${2:?--dom0-url needs a URL}"; shift 2 ;;
        --debian-url)     DEBIAN_URL="${2:?--debian-url needs a URL}"; shift 2 ;;
        --fedora-url)     FEDORA_URL="${2:?--fedora-url needs a URL}"; shift 2 ;;
        *)                die "unknown option: $1 (see --help)" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "run as root (sudo) in dom0"

# Sanity: this is meant for dom0.
if [ -r /etc/qubes-release ] || [ -d /etc/qubes ]; then
    :
else
    warn "this does not look like dom0 (/etc/qubes missing); continuing anyway"
fi

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "  [dry-run] $*"
    else
        eval "$@"
    fi
}

backup_once() {
    # Back up $1 to $1.qbak only if no backup exists yet.
    local f="$1"
    [ -f "$f" ] || return 0
    if [ ! -f "$f.qbak" ]; then
        run "cp -a -- '$f' '$f.qbak'"
    fi
}

# Rewrite every baseurl=/metalink= line under a repo file to point at $2.
# Comments metalink out (mirrors use baseurl). Idempotent.
repoint_repo_file() {
    local file="$1" url="$2"
    [ -f "$file" ] || { warn "not found: $file (skipping)"; return 0; }
    backup_once "$file"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "  [dry-run] set baseurl -> $url in $file"
        return 0
    fi
    # Replace scheme://host[/path-up-to-known-marker] but keep the repo's own
    # sub-path after the marker. Safer approach: rewrite the host+prefix portion
    # only up to '/repo' or '/yum', preserving the tail. To stay robust across
    # layouts we instead rewrite the whole baseurl to "$url/<tail>" where <tail>
    # is whatever followed the 4th '/' in the original. Simpler and predictable:
    # just set baseurl to the provided URL joined with the original path's last
    # two segments is fragile — so we set baseurl to $url and let the repo's
    # relative structure be expressed by the mirror. Document this in mirror.md.
    python3 - "$file" "$url" <<'PY'
import re, sys
path, url = sys.argv[1], sys.argv[2].rstrip('/')
txt = open(path).read()
# Comment out metalink/mirrorlist (mirrors serve via baseurl).
txt = re.sub(r'(?m)^(\s*)(metalink|mirrorlist)\s*=', r'\1#\2=', txt)
# Repoint baseurl host+prefix, preserving the path tail after the release marker.
def fix(m):
    full = m.group(0)
    old = m.group('u')
    # Keep the path tail after the first occurrence of a release-ish marker.
    tail = ''
    for marker in ('/repo/', '/yum/', '/r4', '/current', '/pub/'):
        i = old.find(marker)
        if i != -1:
            tail = old[i:]
            break
    if not tail:
        # Fall back: keep everything after scheme://host
        mm = re.match(r'[a-z]+://[^/]+(/.*)?', old)
        tail = mm.group(1) or '' if mm else ''
    return 'baseurl=' + url + tail
txt = re.sub(r'(?m)^\s*baseurl\s*=\s*(?P<u>\S+)', fix, txt)
open(path, 'w').write(txt)
PY
    echo "  repointed baseurl -> $url in $file"
}

do_disable() {
    info "Reverting mirror changes (restoring *.qbak)..."
    local found=0
    for f in "$REPO_TEMPLATES"/*.repo "$DOM0_REPO"; do
        if [ -f "$f.qbak" ]; then
            run "mv -f -- '$f.qbak' '$f'"
            echo "  restored $f"
            found=1
        fi
    done
    [ "$found" -eq 1 ] || warn "no *.qbak backups found; nothing to restore"
    info "Done. Original sources restored."
}

print_in_template_steps() {
    local distro="$1" url="$2" tpl_hint="$3"
    cat <<EOF

------------------------------------------------------------------
  In-template mirror (${distro}) cannot be set from dom0.
  Run these INSIDE the template qube (e.g. ${tpl_hint}), then shut it down:
------------------------------------------------------------------
EOF
    if [ "$distro" = "debian" ]; then
        cat <<EOF
  sudo cp -a /etc/apt/sources.list /etc/apt/sources.list.qbak 2>/dev/null || true
  # Point Debian at the mirror (adjust suite: trixie=13, bookworm=12):
  sudo sed -i -E 's#https?://[^ ]*deb.debian.org#${url}#g' \\
      /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null || true
  sudo apt-get update
EOF
    else
        cat <<EOF
  # Disable metalink/mirrorlist and set an explicit baseurl on the mirror.
  sudo sed -i -E 's#^(metalink|mirrorlist)=#\#&#' /etc/yum.repos.d/fedora*.repo
  # Add a baseurl to the [fedora] and [updates] repos (adjust the mirror's
  # path layout as needed; see docs/mirror.md):
  #   [fedora]  baseurl=${url}/releases/\\\$releasever/Everything/\\\$basearch/os/
  #   [updates] baseurl=${url}/updates/\\\$releasever/Everything/\\\$basearch/
  sudoedit /etc/yum.repos.d/fedora.repo   # add the baseurl lines above
  sudo dnf clean all && sudo dnf makecache
EOF
    fi
    echo "------------------------------------------------------------------"
}

# ---- main ----

if [ "$DISABLE" -eq 1 ]; then
    do_disable
    exit 0
fi

if [ -z "$TEMPLATES_URL$DOM0_URL$DEBIAN_URL$FEDORA_URL" ]; then
    die "nothing to do: pass at least one --*-url (or --disable). See --help"
fi

# Layer 1: template download source (dom0).
if [ -n "$TEMPLATES_URL" ]; then
    info "Layer 1: Qubes template download source -> $TEMPLATES_URL"
    if [ -d "$REPO_TEMPLATES" ]; then
        for f in "$REPO_TEMPLATES"/*.repo; do
            [ -e "$f" ] || continue
            repoint_repo_file "$f" "$TEMPLATES_URL"
        done
    else
        warn "$REPO_TEMPLATES not found; is qubes-repo-templates installed?"
    fi
fi

# Layer 3 (dom0 update source).
if [ -n "$DOM0_URL" ]; then
    info "Layer 3: dom0 update source -> $DOM0_URL"
    repoint_repo_file "$DOM0_REPO" "$DOM0_URL"
fi

# Layer 2 (in-template): print steps, cannot change from dom0.
[ -n "$DEBIAN_URL" ] && print_in_template_steps debian "$DEBIAN_URL" "debian-13-minimal"
[ -n "$FEDORA_URL" ] && print_in_template_steps fedora "$FEDORA_URL" "fedora-43-minimal"

info "Done."
if [ -n "$TEMPLATES_URL" ]; then
    cat <<'EOF'

Next: retry the template download, e.g.
  sudo qubes-dom0-update --clean qubes-template-debian-13-minimal
  # or
  qvm-template install debian-13-minimal

Revert anytime with:
  sudo ./scripts/qubes-mirror.sh --disable
EOF
fi
