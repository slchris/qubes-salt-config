#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright 2026 Chris Su
#
# Package script for qubes-salt-config
# Creates a tarball for deployment to new machines

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_NAME="qubes-salt-config"
VERSION="${1:-$(date +%Y%m%d)}"
OUTPUT_DIR="${PROJECT_DIR}/dist"
ARCHIVE_NAME="${PROJECT_NAME}-${VERSION}.tar.gz"

usage() {
    echo "Usage: ${0##*/} [VERSION]"
    echo ""
    echo "Package qubes-salt-config for deployment."
    echo ""
    echo "Arguments:"
    echo "  VERSION    Version string (default: current date YYYYMMDD)"
    echo ""
    echo "Output:"
    echo "  dist/${PROJECT_NAME}-VERSION.tar.gz"
    echo ""
    echo "Examples:"
    echo "  ${0##*/}           # Creates ${PROJECT_NAME}-$(date +%Y%m%d).tar.gz"
    echo "  ${0##*/} v1.0.0    # Creates ${PROJECT_NAME}-v1.0.0.tar.gz"
    echo ""
}

info() {
    echo "==> $1"
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

info "Packaging ${PROJECT_NAME} version ${VERSION}..."

# Create tarball (exclude unnecessary files)
cd "$PROJECT_DIR"

# On macOS, set COPYFILE_DISABLE to prevent AppleDouble files (._*)
export COPYFILE_DISABLE=1

tar --exclude='.git' \
    --exclude='.gitignore' \
    --exclude='.DS_Store' \
    --exclude='._*' \
    --exclude='dist' \
    --exclude='*.pyc' \
    --exclude='__pycache__' \
    --exclude='.vscode' \
    --exclude='.idea' \
    -czf "${OUTPUT_DIR}/${ARCHIVE_NAME}" \
    -C "$(dirname "$PROJECT_DIR")" \
    "$(basename "$PROJECT_DIR")"

# Show result
ARCHIVE_SIZE=$(ls -lh "${OUTPUT_DIR}/${ARCHIVE_NAME}" | awk '{print $5}')

echo ""
info "Package created successfully!"
echo ""
echo "  File: ${OUTPUT_DIR}/${ARCHIVE_NAME}"
echo "  Size: ${ARCHIVE_SIZE}"
echo ""
echo "============================================================"
echo "  DEPLOYMENT INSTRUCTIONS"
echo "============================================================"
echo ""
echo "  1. Transfer archive to a Qubes qube (via USB, network, etc.)"
echo "     Example: copy ${ARCHIVE_NAME} to ~/Downloads in a qube"
echo ""
echo "  2. In the qube, extract the archive:"
echo "     cd ~"
echo "     tar -xzf Downloads/${ARCHIVE_NAME}"
echo ""
echo "  3. In dom0, copy from the qube:"
echo "     qube=\"CHANGEME\"  # Your qube name"
echo "     mkdir -p ~/QubesIncoming/\"\${qube}\""
echo "     qvm-run --no-gui --pass-io -- \"\${qube}\" \\"
echo "       \"tar -cf - -C ~ ${PROJECT_NAME}\" | \\"
echo "       tar -xf - -C ~/QubesIncoming/\"\${qube}\""
echo ""
echo "  4. In dom0, run setup:"
echo "     cd ~/QubesIncoming/\"\${qube}\"/${PROJECT_NAME}"
echo "     sudo ./scripts/setup.sh"
echo ""
echo "  5. Setup management environment:"
echo "     sudo qubesctl top.enable mgmt"
echo "     sudo qubesctl --targets=tpl-mgmt state.apply"
echo "     sudo qubesctl top.disable mgmt"
echo "     sudo qubesctl state.apply mgmt.prefs"
echo ""
echo "============================================================"
echo ""

# Also create a checksum
cd "$OUTPUT_DIR"
sha256sum "${ARCHIVE_NAME}" > "${ARCHIVE_NAME}.sha256"
info "Checksum: ${OUTPUT_DIR}/${ARCHIVE_NAME}.sha256"
