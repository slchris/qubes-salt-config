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

# Source and destination directories
SALT_SRC="${PROJECT_DIR}/salt"
PILLAR_SRC="${PROJECT_DIR}/pillar"
MINION_SRC="${PROJECT_DIR}/minion.d"
SALT_DST="/srv/salt/${PROJECT}"
PILLAR_DST="/srv/pillar/${PROJECT}"
MINION_DST="/etc/salt/minion.d"

# Check source directories exist
[ -d "$SALT_SRC" ] || die "Salt source directory not found: $SALT_SRC"
[ -d "$PILLAR_SRC" ] || die "Pillar source directory not found: $PILLAR_SRC"
[ -d "$MINION_SRC" ] || die "Minion config source directory not found: $MINION_SRC"

echo ""
echo "  qubes-salt-config setup (${PROJECT})"
echo "  ====================================="
echo ""
echo "Source directories:"
echo "  Salt:   $SALT_SRC"
echo "  Pillar: $PILLAR_SRC"
echo "  Minion: $MINION_SRC"
echo ""
echo "Destination directories:"
echo "  Salt:   $SALT_DST"
echo "  Pillar: $PILLAR_DST"
echo "  Minion: $MINION_DST"
echo ""

if [ "$DRY_RUN" -eq 1 ]; then
    echo "[DRY RUN] Would perform the following actions:"
    echo ""
fi

# Clean old installation
if [ "$DRY_RUN" -eq 1 ]; then
    echo "  rm -rf $SALT_DST"
    echo "  rm -rf $PILLAR_DST"
else
    info "Cleaning old installation..."
    rm -rf "$SALT_DST"
    rm -rf "$PILLAR_DST"
fi

# Create destination directories
if [ "$DRY_RUN" -eq 1 ]; then
    echo "  mkdir -p $SALT_DST"
    echo "  mkdir -p $PILLAR_DST"
else
    info "Ensuring directories exist..."
    mkdir -p "$SALT_DST"
    mkdir -p "$PILLAR_DST"
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

# Copy pillar files
if [ "$DRY_RUN" -eq 1 ]; then
    echo "  cp -r $PILLAR_SRC/* $PILLAR_DST/"
else
    info "Copying pillar files..."
    cp -r "$PILLAR_SRC"/* "$PILLAR_DST"/
fi

# Sync salt modules
if [ "$DRY_RUN" -eq 1 ]; then
    echo "  qubesctl saltutil.sync_all"
    echo "  qubesctl saltutil.refresh_pillar"
else
    info "Syncing salt modules..."
    qubesctl saltutil.sync_all
    
    info "Refreshing pillar data..."
    qubesctl saltutil.refresh_pillar
fi

echo ""
info "Setup complete!"
echo ""
echo "============================================================"
echo "  NEXT STEPS - READ CAREFULLY"
echo "============================================================"
echo ""
echo "  Files deployed to /srv/salt/${PROJECT} and /srv/pillar/${PROJECT}"
echo "  The minion config sets this as the ONLY file_root (like qusal)"
echo "  So you DON'T need a prefix when applying states"
echo ""
echo "  1. Install base templates (REQUIRED FIRST):"
echo "     sudo qubesctl state.apply debian-minimal.clone"
echo "     sudo qubesctl state.apply fedora-minimal.clone"
echo ""
echo "  2. Create base DVM templates:"
echo "     sudo qubesctl state.apply debian-minimal.create"
echo "     sudo qubesctl state.apply fedora-minimal.create"
echo ""
echo "  3. Edit your configuration:"
echo "     sudo vim /srv/pillar/${PROJECT}/user.sls"
echo "     sudo qubesctl saltutil.refresh_pillar"
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
