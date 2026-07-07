{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Configure the mcp qube for MCP-server / AI-application development:
  - a projects workspace directory
  - a per-user npm prefix so `npm i -g` needs no root
  - a .env.example documenting expected API-key variables (NOT a real key)

API keys are secrets: keep them in the AppVM's private storage (e.g. a real
.env you create yourself, or a split-secret setup), never in the template and
never committed. This state only writes a non-secret example file.

Runs inside the target qube (mcp), not dom0.
#}

{% if grains['nodename'] != 'dom0' %}

"mcp-projects-dir":
  file.directory:
    - name: /home/user/projects
    - user: user
    - group: user
    - mode: '0755'

# Per-user global npm prefix so `npm install -g <tool>` works without sudo.
"mcp-npm-prefix-dir":
  file.directory:
    - name: /home/user/.npm-global
    - user: user
    - group: user
    - mode: '0755'

"mcp-npmrc":
  file.managed:
    - name: /home/user/.npmrc
    - user: user
    - group: user
    - mode: '0644'
    - contents: |
        prefix=/home/user/.npm-global
    - require:
      - file: mcp-npm-prefix-dir

"mcp-path-profile":
  file.managed:
    - name: /home/user/.profile.d-npm-global.sh
    - user: user
    - group: user
    - mode: '0644'
    - contents: |
        # Added by qubes-salt-config templates.mcp.configure
        export PATH="$HOME/.npm-global/bin:$PATH"

"mcp-bashrc-source-npm":
  file.append:
    - name: /home/user/.bashrc
    - text: |
        # qubes-salt-config: MCP dev PATH
        [ -f "$HOME/.profile.d-npm-global.sh" ] && . "$HOME/.profile.d-npm-global.sh"
    - require:
      - file: mcp-path-profile

# Example env file documenting expected keys. This is NOT a secret; create a
# real .env yourself with your keys and keep it out of version control.
"mcp-env-example":
  file.managed:
    - name: /home/user/projects/.env.example
    - user: user
    - group: user
    - mode: '0600'
    - contents: |
        # Copy to .env and fill in. Do NOT commit real keys.
        ANTHROPIC_API_KEY=
        OPENAI_API_KEY=
        # MCP servers usually take config via args/stdio, not env; add as needed.
    - require:
      - file: mcp-projects-dir

{% endif %}
