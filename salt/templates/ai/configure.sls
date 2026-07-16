{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Configure the ai / dvm-ai qubes (runs inside the qubes, not dom0):
  - /home/user/projects workspace (persists on the AppVM private volume)
  - per-user npm prefix so `npm i -g` needs no root
  - PATH wiring for ~/.npm-global/bin and ~/.local/bin
  - a non-secret .env.example documenting expected API-key variables
  - Claude Code CLI via the native installer into ~/.local (self-updating,
    survives reboots with no template change)

The CLI install needs network THROUGH sys-project-net, so it only runs when
the tunnel actually works (onlyif reachability probe) — otherwise it is
skipped this apply; re-apply once the VPN is up, or run the same curl
yourself inside the qube.

API keys / login tokens are secrets: they live in the AppVM's private volume
(~/.config/Claude, a real .env you create), never in the template and never
in salt.
#}

{% if grains['nodename'] != 'dom0' %}

"ai-projects-dir":
  file.directory:
    - name: /home/user/projects
    - user: user
    - group: user
    - mode: '0755'

"ai-npm-prefix-dir":
  file.directory:
    - name: /home/user/.npm-global
    - user: user
    - group: user
    - mode: '0755'

"ai-npmrc":
  file.managed:
    - name: /home/user/.npmrc
    - user: user
    - group: user
    - mode: '0644'
    - contents: |
        prefix=/home/user/.npm-global
    - require:
      - file: ai-npm-prefix-dir

"ai-path-profile":
  file.managed:
    - name: /home/user/.profile.d-ai.sh
    - user: user
    - group: user
    - mode: '0644'
    - contents: |
        # Added by qubes-salt-config templates.ai.configure
        export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"

"ai-bashrc-source-path":
  file.append:
    - name: /home/user/.bashrc
    - text: |
        # qubes-salt-config: AI workbench PATH
        [ -f "$HOME/.profile.d-ai.sh" ] && . "$HOME/.profile.d-ai.sh"
    - require:
      - file: ai-path-profile

# Example env file documenting expected keys. NOT a secret; create a real
# .env yourself and keep it out of version control.
"ai-env-example":
  file.managed:
    - name: /home/user/projects/.env.example
    - user: user
    - group: user
    - mode: '0600'
    - contents: |
        # Copy to .env and fill in. Do NOT commit real keys.
        ANTHROPIC_API_KEY=
        OPENAI_API_KEY=
    - require:
      - file: ai-projects-dir

# Claude Code CLI — native installer into ~/.local/bin (the recommended,
# self-updating install; npm would pin an old version). Home-dir install is
# ideal in Qubes: persists in the AppVM, no template rebuild to update.
# Download-then-run (not `curl | bash`: without pipefail a failed download
# would exit 0 via bash-on-empty-stdin and salt would report success), and
# verify the binary actually landed so a broken install fails the apply.
"ai-claude-code-cli":
  cmd.run:
    - name: |
        set -e
        curl -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh
        bash /tmp/claude-install.sh
        rm -f /tmp/claude-install.sh
        test -x /home/user/.local/bin/claude
    - runas: user
    - env:
      - HOME: /home/user
    - unless: test -x /home/user/.local/bin/claude
    - onlyif: curl -fsm 8 -o /dev/null https://claude.ai
    - require:
      - file: ai-path-profile

{% endif %}
