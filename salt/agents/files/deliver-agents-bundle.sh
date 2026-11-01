#!/bin/bash
# SPDX-FileCopyrightText: 2026 Chris Su
# SPDX-License-Identifier: MIT
#
# Deliver the newest agent bundle from agent-build to tpl-agents (dom0).
#
# Usage: deliver-agents-bundle.sh <build-qube> <template> <bundle-dir>
#
# The bundle is pulled through qrexec as a binary stream, verified against the
# build qube's sha256 (and again inside the template), then extracted over
# /opt/agents-bundle. Only the current debs/ and wrappers/ are replaced; old
# version directories remain for rollback, and old bundles stay in the build
# qube's bundle-dir.
#
# qvm-run starts a halted qube. The template is left running; shut it down
# before starting AppVMs based on it so they pick up the new root volume.

set -eu

BUILD_QUBE="${1:?usage: $0 <build-qube> <template> <bundle-dir>}"
TEMPLATE="${2:?usage: $0 <build-qube> <template> <bundle-dir>}"
BUNDLE_DIR="${3:?usage: $0 <build-qube> <template> <bundle-dir>}"

qvm-check "$BUILD_QUBE" >/dev/null 2>&1 || { echo "no such qube: $BUILD_QUBE" >&2; exit 1; }
qvm-check "$TEMPLATE" >/dev/null 2>&1 || { echo "no such qube: $TEMPLATE" >&2; exit 1; }

BUNDLE="$(qvm-run --pass-io -- "$BUILD_QUBE" "cat '${BUNDLE_DIR}/latest.path'" 2>/dev/null || true)"
[ -n "$BUNDLE" ] || { echo "no bundle: ${BUILD_QUBE}:${BUNDLE_DIR}/latest.path (run agents.build.run first)" >&2; exit 1; }

SHA="$(qvm-run --pass-io -- "$BUILD_QUBE" "sha256sum '${BUNDLE}' | cut -d' ' -f1")"
[ -n "$SHA" ] || { echo "could not hash ${BUNDLE}" >&2; exit 1; }
LATEST_SHA="$(qvm-run --pass-io -- "$BUILD_QUBE" "cut -d' ' -f1 '${BUNDLE_DIR}/latest.sha256'")"
[ "$SHA" = "$LATEST_SHA" ] || { echo "sha mismatch: ${BUNDLE} != latest.sha256" >&2; exit 1; }

HAVE="$(qvm-run --pass-io -u root -- "$TEMPLATE" "cat /opt/agents-bundle/.bundle-sha256 2>/dev/null || true")"
if [ "$HAVE" = "$SHA" ]; then
    echo "already installed: ${TEMPLATE} has bundle ${SHA}"
    exit 0
fi

echo "==> ${TEMPLATE} <- ${BUILD_QUBE}:${BUNDLE}"
echo "    sha256 ${SHA}"

# /tmp is a 1G tmpfs in an AppVM/TemplateVM; the bundle is about 1G. Use the
# template's root volume for the staging file.
qvm-run --pass-io -- "$BUILD_QUBE" "cat '${BUNDLE}'" \
    | qvm-run --pass-io -u root -- "$TEMPLATE" "cat > /var/tmp/agents-bundle.tar.gz"

printf '%s  %s\n' "$SHA" /var/tmp/agents-bundle.tar.gz \
    | qvm-run --pass-io -u root -- "$TEMPLATE" "sha256sum -c -"

# Keep versioned node/ and agents/ trees; replace only the current deb/wrapper
# selections, then run the bundle's own installer.
qvm-run --pass-io -u root -- "$TEMPLATE" "
    rm -rf /opt/agents-bundle/debs /opt/agents-bundle/wrappers
    mkdir -p /opt/agents-bundle
    tar -xzf /var/tmp/agents-bundle.tar.gz -C /opt/agents-bundle
    /opt/agents-bundle/install.sh '$SHA'
"

echo "done: ${TEMPLATE} now has bundle ${SHA}"
echo "note: shut down ${TEMPLATE} before (re)starting AppVMs so they see the new root"
