#!/bin/bash
# SPDX-FileCopyrightText: 2026 Chris Su
# SPDX-License-Identifier: MIT
#
# Install an agent bundle inside tpl-agents (or any Debian template).
#
# The bundle is already extracted at /opt/agents-bundle by agents.deliver.
# Argument 1 is the bundle sha256; when present and /tmp/agents-bundle.tar.gz
# still exists, the archive is verified before anything is installed.
#
# Version policy:
#   - npm agents are versioned directories under /opt/agents-bundle/agents/;
#     old versions are left in place, and /usr/local/bin/<bin> points at the
#     version selected by the bundle.
#   - the .deb agent is installed system-wide with dpkg; the pinned .deb stays
#     in the bundle for rollback.
#   - self-update is disabled in the template. Updates come from a new bundle
#     applied by agents.deliver, then an AppVM restart.

set -eu

BUNDLE=/opt/agents-bundle
EXPECTED_SHA="${1:-}"

[ -d "$BUNDLE" ] || { echo "missing $BUNDLE" >&2; exit 1; }
[ -f "$BUNDLE/install.sh" ] || { echo "missing $BUNDLE/install.sh" >&2; exit 1; }

if [ -n "$EXPECTED_SHA" ] && [ -f /tmp/agents-bundle.tar.gz ]; then
    printf '%s  %s\n' "$EXPECTED_SHA" /tmp/agents-bundle.tar.gz | sha256sum -c -
fi

echo "==> installing pinned .deb agents"
if compgen -G "${BUNDLE}/debs/*.deb" >/dev/null; then
    for deb in "${BUNDLE}"/debs/*.deb; do
        echo "    dpkg -i $(basename "$deb")"
        dpkg -i "$deb"
    done
else
    echo "    (no .deb agents in this bundle)"
fi

echo "==> installing npm agent launchers"
install -d -m 0755 /usr/local/bin
if compgen -G "${BUNDLE}/wrappers/*" >/dev/null; then
    for wrapper in "${BUNDLE}"/wrappers/*; do
        install -m 0755 "$wrapper" "/usr/local/bin/$(basename "$wrapper")"
    done
else
    echo "    (no npm agents in this bundle)"
fi

# Claude Code reads managed settings from this path. DISABLE_UPDATES blocks
# both the background updater and `claude update` / `claude install`: the
# binary is owned by the template, and an AppVM must not grow a shadow copy
# under ~/.local that survives template updates.
echo "==> writing Claude Code managed settings"
install -d -m 0755 /etc/claude-code
cat > /etc/claude-code/managed-settings.json <<'JSON'
{
  "env": {
    "DISABLE_UPDATES": "1"
  }
}
JSON
chmod 0644 /etc/claude-code/managed-settings.json

# PATH for the bundled Node, and the one agent that has an auto-update default
# we must neutralize at the environment level.
echo "==> writing agent environment"
install -d -m 0755 /etc/profile.d /etc/environment.d
cat > /etc/profile.d/agents.sh <<'SH'
# Managed by qubes-salt-config agents.template
export PATH="/opt/agents-bundle/node/current/bin:$PATH"
export OPENCODE_DISABLE_AUTOUPDATE=true
SH
chmod 0644 /etc/profile.d/agents.sh
cat > /etc/environment.d/90-agents.conf <<'CONF'
OPENCODE_DISABLE_AUTOUPDATE=true
CONF
chmod 0644 /etc/environment.d/90-agents.conf

if [ -n "$EXPECTED_SHA" ]; then
    printf '%s\n' "$EXPECTED_SHA" > "${BUNDLE}/.bundle-sha256"
fi

echo "==> installed:"
printf '    '
command -v claude >/dev/null 2>&1 && printf 'claude '
command -v codex >/dev/null 2>&1 && printf 'codex '
command -v opencode >/dev/null 2>&1 && printf 'opencode '
command -v pi >/dev/null 2>&1 && printf 'pi '
command -v grok >/dev/null 2>&1 && printf 'grok '
echo
echo "done"
