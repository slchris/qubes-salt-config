#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright 2026 Chris Su
#
# Setup script for qubes-salt-config (slchris)
# Copies salt and pillar files to /srv/salt/slchris and /srv/pillar/slchris

set -eu

usage() {
    echo "Usage: ${0##*/} [OPTIONS]"
    echo ""
    echo "Setup qubes-salt-config by copying files to Salt directories."
    echo ""
    echo "Options:"
    echo "  -h, --help     Show this help message"
    echo "  -n, --dry-run  Show what would be done without making changes"
    echo ""
}

die() {
    echo "Error: $1" >&2
    exit 1
}

info() {
    echo "==> $1"
}

# Default values
DRY_RUN=0

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -n|--dry-run)
            DRY_RUN=1
            shift
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    die "This script must be run as root (use sudo)"
fi

# Project name (used for directory naming)
PROJECT="slchris"

# Source and destination directories.
# NOTE: this project does NOT use Salt pillar (see minion.d/slchris.conf). All
# user config lives in salt/config.jinja. We still actively REMOVE any old
# /srv/pillar/slchris that earlier versions deployed, because a bare top.sls
# there breaks Qubes dom0 pillar loading system-wide.
SALT_SRC="${PROJECT_DIR}/salt"
MINION_SRC="${PROJECT_DIR}/minion.d"
SALT_DST="/srv/salt/${PROJECT}"
PILLAR_DST="/srv/pillar/${PROJECT}"
MINION_DST="/etc/salt/minion.d"

# Check source directories exist
[ -d "$SALT_SRC" ] || die "Salt source directory not found: $SALT_SRC"
[ -d "$MINION_SRC" ] || die "Minion config source directory not found: $MINION_SRC"

echo ""
echo "  qubes-salt-config setup (${PROJECT})"
echo "  ====================================="
echo ""
echo "Source directories:"
echo "  Salt:   $SALT_SRC"
echo "  Minion: $MINION_SRC"
echo ""
echo "Destination directories:"
echo "  Salt:   $SALT_DST"
echo "  Minion: $MINION_DST"
echo "  (pillar is NOT used; any old $PILLAR_DST is removed)"
echo ""

if [ "$DRY_RUN" -eq 1 ]; then
    echo "[DRY RUN] Would perform the following actions:"
    echo ""
fi

# Clean old installation. Removing $PILLAR_DST is important: a stale bare
# top.sls there breaks Qubes dom0 pillar loading. This project uses no pillar.
if [ "$DRY_RUN" -eq 1 ]; then
    echo "  rm -rf $SALT_DST"
    echo "  rm -rf $PILLAR_DST   # remove old, broken pillar deployment"
else
    info "Cleaning old installation (incl. any old pillar)..."
    rm -rf "$SALT_DST"
    rm -rf "$PILLAR_DST"
fi

# Create destination directory
if [ "$DRY_RUN" -eq 1 ]; then
    echo "  mkdir -p $SALT_DST"
else
    info "Ensuring directories exist..."
    mkdir -p "$SALT_DST"
fi

# Copy minion config
if [ "$DRY_RUN" -eq 1 ]; then
    echo "  cp $MINION_SRC/*.conf $MINION_DST/"
else
    info "Installing minion configuration..."
    cp "$MINION_SRC"/*.conf "$MINION_DST"/
fi

# Copy salt files
if [ "$DRY_RUN" -eq 1 ]; then
    echo "  cp -r $SALT_SRC/* $SALT_DST/"
else
    info "Copying salt files..."
    cp -r "$SALT_SRC"/* "$SALT_DST"/
fi

# Sync salt modules (no pillar to refresh — this project uses config.jinja).
if [ "$DRY_RUN" -eq 1 ]; then
    echo "  qubesctl saltutil.sync_all"
else
    info "Syncing salt modules..."
    qubesctl saltutil.sync_all
fi

echo ""
info "Setup complete!"
echo ""
echo "============================================================"
echo "  NEXT STEPS - READ CAREFULLY"
echo "============================================================"
echo ""
echo "  Files deployed to /srv/salt/${PROJECT} (added to file_roots)."
echo "  No prefix needed when applying states (like qusal)."
echo "  Configuration is in /srv/salt/${PROJECT}/config.jinja (NOT pillar)."
echo ""
echo "  1. Edit your configuration (versions, mirror, remote-debug, ...):"
echo "     sudo vim /srv/salt/${PROJECT}/config.jinja"
echo "     # takes effect on the next state.apply; no refresh_pillar needed"
echo ""
echo "  2. Install base templates (REQUIRED FIRST):"
echo "     sudo qubesctl state.apply debian-minimal.clone"
echo "     sudo qubesctl state.apply fedora-minimal.clone"
echo ""
echo "  3. Create base DVM templates:"
echo "     sudo qubesctl state.apply debian-minimal.create"
echo "     sudo qubesctl state.apply fedora-minimal.create"
echo ""
echo "  4. Create templates (example: dev):"
echo "     sudo qubesctl state.apply templates.dev.create"
echo "     sudo qubesctl --skip-dom0 --targets=tpl-dev state.apply templates.dev.install"
echo ""
echo "============================================================"
echo "  AVAILABLE TEMPLATES"
echo "============================================================"
echo ""
echo "  Debian-based (debian-13-minimal):"
echo "    - templates.dev        : Development environment"
echo "    - templates.media      : Multimedia playback"
echo "    - templates.im         : Instant messaging"
echo "    - templates.tools      : General utilities"
echo "    - templates.gpg        : GPG key management (offline)"
echo "    - templates.vault      : Password management (offline)"
echo "    - templates.mcp        : MCP server & AI app development"
echo ""
echo "  Fedora-based (fedora-43-minimal):"
echo "    - templates.vpn        : VPN gateway (WireGuard, OpenVPN)"
echo ""
echo "  Gentoo-based (gentoo-xfce, requires qubes-builder; see salt/gentoo):"
echo "    - templates.gentoo-dev : Ebuild / package development"
echo ""
echo "============================================================"
echo "  QUSAL-STYLE USAGE"
echo "============================================================"
echo ""
echo "  This project follows patterns from qusal project:"
echo "  https://github.com/ben-grande/qusal"
echo ""
echo "  Key concepts:"
echo "    - clone.sls : Downloads/clones base template"
echo "    - create.sls: Creates qubes (tpl-*, dvm-*, appvm)"
echo "    - install.sls: Installs packages in templates"
echo "    - configure.sls: Configures running qubes"
echo ""
echo "  Macros available:"
echo "    - clone_template: Clone templates easily"
echo "    - sync_appmenus: Sync application menus"
echo "    - policy_set/unset: Manage RPC policies"
echo ""
echo "============================================================"
echo ""
