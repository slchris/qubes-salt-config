{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Verify the agent bundle in tpl-agents. Run after agents.deliver.

This is intentionally a hard check: a template that is missing an agent, or
whose launcher points at a missing version tree, should fail here rather than
at first use in a project qube. `--version` does not need network, and Claude
Code's DISABLE_UPDATES managed setting is checked explicitly.
#}

{% if grains['nodename'] != 'dom0' %}

"agents-verify":
  cmd.run:
    - name: |
        set -eu
        mkdir -p /tmp/agents-verify
        test -x /opt/agents-bundle/node/current/bin/node
        grep -q 'DISABLE_UPDATES' /etc/claude-code/managed-settings.json
        for c in claude codex opencode pi grok; do
          command -v "$c" >/dev/null
          printf '%s: ' "$c"
          timeout 20 "$c" --version
        done
        # GUI apps used for OAuth and the shared desktop, plus the input/audio
        # pieces the agent qubes need. Do not run --version for the GUI apps:
        # some of them launch a window instead of printing a version.
        for b in google-chrome code claude-desktop; do
          command -v "$b" >/dev/null
          printf '%s: %s\n' "$b" "$(command -v "$b")"
        done
        if command -v fcitx5 >/dev/null; then
          echo "fcitx5 is installed; agent qubes do not use a zh_CN locale" >&2
          exit 1
        fi
        for p in fonts-noto-cjk fonts-noto-cjk-extra; do
          if dpkg -s "$p" >/dev/null 2>&1; then
            echo "$p is installed; agent qubes do not ship CJK fonts" >&2
            exit 1
          fi
        done
        if fc-list : family | grep -E -q 'Noto (Sans|Serif|Sans Mono) CJK|WenQuanYi|AR PL'; then
          echo "CJK font families are still registered" >&2
          exit 1
        fi
        grep -q '"WebRtcIPHandling": "disable_non_proxied_udp"' \
          /etc/opt/chrome/policies/managed/webrtc.json
        test -f /usr/share/applications/com.google.Chrome.desktop
        dpkg -s pulseaudio-qubes >/dev/null
        test -x /usr/lib/qubes-agents/apply-exit.sh
        locale -a | grep -qi '^en_US.utf8$'
        test -s /etc/timezone
        printf 'timezone: '; cat /etc/timezone
        printf 'locale: '; cat /etc/default/locale
    - runas: user
    - env:
      - HOME: /tmp/agents-verify
    - shell: /bin/bash

{% endif %}
