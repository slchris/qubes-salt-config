# ai

AI agent workbench for Qubes OS: Claude Desktop + Claude Code behind a
dedicated, fail-closed project VPN.

## Table of Contents

*   [Description](#description)
*   [Installation](#installation)
*   [Claude Desktop notes](#claude-desktop-notes)
*   [Claude Code CLI](#claude-code-cli)
*   [Usage](#usage)
*   [Notes and limitations](#notes-and-limitations)

## Description

Creates a persistent `ai` AppVM (plus `dvm-ai` for throwaway agent runs)
whose **netvm is pinned to `sys-project-net`**
([templates/project-net](../project-net/)): everything the agent does —
API calls, git pushes, package pulls — goes through that project's WireGuard
tunnel, and nothing leaks if the tunnel is down.

Project code lives in `/home/user/projects` on the AppVM's private volume:
it persists across reboots and is included in backups. The dev base matches
[templates/mcp](../mcp/) (python3/pip/venv, pipx, uv, Debian nodejs/npm, git);
AI SDKs are per-project deps (`uv add anthropic`, `npm i @anthropic-ai/sdk`),
not system packages.

## Installation

**Deploy [templates/project-net](../project-net/) first** — including its
wg0.conf. The `ai` qube's netvm points at sys-project-net; starting it before
the gateway is configured means no (or worse, unfiltered) network.

```sh
# 1. Create qubes (also pulls in project-net's create via include)
sudo qubesctl top.enable templates.ai
sudo qubesctl state.apply templates.ai.create

# 2. Install packages in the template
sudo qubesctl --skip-dom0 --targets=tpl-ai state.apply templates.ai.install

# 3. Refresh dom0 menu entries (Claude Desktop appears after install)
qvm-sync-appmenus tpl-ai

# 4. Configure the AppVMs
sudo qubesctl --skip-dom0 --targets=ai state.apply templates.ai.configure
sudo qubesctl --skip-dom0 --targets=dvm-ai state.apply templates.ai.configure
sudo qubesctl top.disable templates.ai
```

## Claude Desktop notes

Installed from Anthropic's **official Linux apt repo** (beta since June
2026): `https://downloads.claude.ai/claude-desktop/apt/stable`, package
`claude-desktop`. The repo doubles as the update channel (no in-app updater
on Linux) — rerunning `templates.ai.install` updates the app.

*   **CN-network caveat**: downloads.claude.ai has no China mirror; the
    template reaches it only via the Qubes update-proxy. The claude-desktop
    states are leaf states — if they fail, the rest of the template still
    installs. Retry later, or install manually: download the .deb in any
    networked qube from the repo pool
    (`https://downloads.claude.ai/claude-desktop/apt/stable/pool/main/c/claude-desktop/`),
    `qvm-copy-to-vm tpl-ai <file>.deb`, then in tpl-ai:
    `sudo apt install /home/user/QubesIncoming/*/claude-desktop_*.deb`.
*   **Login**: claude.ai subscription (or SSO) only — Console API keys don't
    work in Desktop; use the CLI for API-key auth.
*   **Credential storage**: gnome-keyring + libsecret are installed, but in a
    Qubes AppVM no keyring daemon is unlocked at login, so the app falls back
    to the basic store (login persists in `~/.config/Claude`, just without
    Secret-Service encryption). Acceptable inside a dedicated qube; start
    `gnome-keyring-daemon` in your session if you want the stronger store.
*   **Cowork does not work in Qubes** (it needs nested KVM, which Qubes does
    not expose). Chat and Code tabs work. Dictation is not in the Linux beta.

## Claude Code CLI

`templates.ai.configure` installs the CLI with the official native installer
into `~/.local/bin/claude` (self-updating, persists in the AppVM — no
template rebuild for updates). The step needs working network through
sys-project-net; if the tunnel was down during configure it is skipped —
re-apply, or run inside the qube:

```sh
curl -fsSL https://claude.ai/install.sh | bash
```

## Usage

```sh
qvm-run -q ai 'claude-desktop'      # or launch from the app menu
qvm-run -q ai 'xterm'               # terminal; `claude` inside ~/projects
```

Keep secrets (real `.env`, API keys) in the AppVM only — see
`~/projects/.env.example`.

## Notes and limitations

*   Want a different VPN for this workbench? Point it at another gateway
    (`qvm-prefs ai netvm sys-other-net`) or copy this unit +
    [project-net](../project-net/) per project.
*   Need more disk for code/node_modules:
    `qvm-volume resize ai:private 50G` (from dom0).
*   Audio is disabled (`audiovm: ""`) like the repo's other workstation
    qubes; unset the pref if you want sound.

## Qubes Created

| Qube | Type | Description |
|------|------|-------------|
| tpl-ai | Template | Debian minimal + Claude Desktop + dev/agent toolchain |
| dvm-ai | DispVM template | Throwaway agent runs (netvm sys-project-net) |
| ai | AppVM | Persistent AI workbench (netvm sys-project-net) |

## License

SPDX-License-Identifier: MIT

Copyright 2026 Chris Su
