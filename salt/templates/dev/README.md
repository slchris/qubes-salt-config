# tpl-dev

Development environment template for Qubes OS.

## Table of Contents

*   [Description](#description)
*   [Installation](#installation)
*   [Packages](#packages)
*   [Usage](#usage)

## Description

Creates a development environment with the following qubes:

| Qube | Type | Description |
|------|------|-------------|
| tpl-dev | Template | Base template with all development tools |
| dvm-dev | DispVM Template | Disposable VM for temporary dev tasks |
| dev | AppVM | Persistent development workspace |

## Installation

### Using Top File (Recommended)

```sh
sudo qubesctl top.enable templates.dev
sudo qubesctl --targets=tpl-dev state.apply
sudo qubesctl top.disable templates.dev

# Optional: Configure with dotfiles
sudo qubesctl --skip-dom0 --targets=dev,dvm-dev state.apply templates.dev.configure
```

### Using State Directly

```sh
# Step 1: Create qubes (in dom0)
sudo qubesctl state.apply templates.dev.create

# Step 2: Install packages in template
sudo qubesctl --skip-dom0 --targets=tpl-dev state.apply templates.dev.install

# Step 3: Configure with dotfiles
sudo qubesctl --skip-dom0 --targets=dev,dvm-dev state.apply templates.dev.configure
```

## Packages

The following packages are installed:

### Development Tools

| Package | Description |
|---------|-------------|
| vim, neovim | Text editors |
| git | Version control |
| tmux | Terminal multiplexer |
| htop | Process viewer |
| ripgrep, fd-find | Modern search tools |
| jq | JSON processor |

### Programming Languages

| Package | Description |
|---------|-------------|
| python3, python3-pip | Python 3 runtime and package manager |
| golang | Go programming language |
| nodejs, npm | Node.js runtime and package manager |
| gcc, gcc-c++, make, cmake | C/C++ build tools |

### IDE

| Package | Description |
|---------|-------------|
| code | Visual Studio Code |

### Network Analysis

| Package | Description |
|---------|-------------|
| wireshark-cli | Network protocol analyzer |
| tcpdump | Packet analyzer |
| nmap | Network scanner |

### Container Tools

| Package | Description |
|---------|-------------|
| podman | Container runtime |
| buildah | Container image builder |

## Usage

After installation:

1. Start the `dev` qube for persistent development work
2. Use `dvm-dev` for temporary/disposable development tasks
3. Install additional packages in `tpl-dev` as needed

### Open VS Code

```sh
qvm-run dev "code"
```

### Go Development

```sh
qvm-run dev "go version"
```
