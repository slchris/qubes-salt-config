# tpl-mcp

MCP server & AI application development environment for Qubes OS.

## Table of Contents

*   [Description](#description)
*   [Installation](#installation)
*   [Toolchain](#toolchain)
*   [Usage](#usage)
*   [API keys & secrets](#api-keys--secrets)

## Description

Creates a Debian-based environment for building **Model Context Protocol (MCP)
servers** (TypeScript and Python SDKs) and **AI applications that call model
APIs** (Anthropic, OpenAI, etc.):

| Qube | Type | Description |
|------|------|-------------|
| tpl-mcp | Template | Node.js LTS + Python + uv toolchain |
| dvm-mcp | DispVM Template | Disposable VM for throwaway MCP/agent runs |
| mcp | AppVM | Persistent MCP/AI development workspace |

The qubes are networked (API calls and package installs). The MCP/AI **SDKs are
per-project dependencies** installed with `npm`/`uv` inside each project, not
system packages, so they are not installed globally in the template.

## Installation

### Using Top File (Recommended)

```sh
sudo qubesctl top.enable templates.mcp
sudo qubesctl --targets=tpl-mcp state.apply
sudo qubesctl top.disable templates.mcp

sudo qubesctl --skip-dom0 --targets=mcp,dvm-mcp state.apply templates.mcp.configure
```

### Using State Directly

```sh
# Step 1: Create qubes (in dom0)
sudo qubesctl state.apply templates.mcp.create

# Step 2: Install toolchain in template
sudo qubesctl --skip-dom0 --targets=tpl-mcp state.apply templates.mcp.install

# Step 3: Configure the workspace
sudo qubesctl --skip-dom0 --targets=mcp,dvm-mcp state.apply templates.mcp.configure
```

## Toolchain

Installed in `tpl-mcp`:

| Tool | Purpose |
|------|---------|
| Node.js 22 LTS (NodeSource) | TypeScript MCP servers, `@modelcontextprotocol/sdk` |
| python3, python3-venv, pipx | Python MCP servers and AI apps |
| uv (astral.sh) | Fast Python project/venv manager (`uv init`, `uv add mcp`) |
| git, build-essential, curl, jq, ripgrep | General development |

`configure` also sets a per-user npm prefix (`~/.npm-global`) so `npm i -g`
works without root, and creates a `~/projects` workspace.

## Usage

### Scaffold a Python MCP server

```sh
qvm-run mcp 'cd ~/projects && uv init my-mcp && cd my-mcp && uv add "mcp[cli]"'
```

### Scaffold a TypeScript MCP server

```sh
qvm-run mcp 'cd ~/projects && npm init -y && npm install @modelcontextprotocol/sdk'
```

### AI application calling an API

```sh
qvm-run mcp 'cd ~/projects && uv init my-app && cd my-app && uv add anthropic openai'
```

## API keys & secrets

**Never put API keys in the template.** `configure` writes only a non-secret
`~/projects/.env.example`. Create a real `.env` yourself in the `mcp` AppVM's
private storage and keep it out of version control. For stronger isolation,
keep keys in a separate vault qube and pass them in per run, rather than storing
them in the networked `mcp` qube at all.
