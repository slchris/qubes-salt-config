# qubes-salt-config

Salt Formulas for Qubes OS.

## Table of Contents

*   [Description](#description)
*   [Installation](#installation)
*   [Templates](#templates)
*   [Usage](#usage)
*   [Project Structure](#project-structure)
*   [Credits](#credits)

## Description

This project provides SaltStack Formulas for [Qubes OS](https://www.qubes-os.org) users to automate system configuration and management tasks. Based on patterns from [qusal](https://github.com/ben-grande/qusal), it provides a clean, modular approach to Qubes configuration management.

**Note**: Files are deployed to `/srv/salt/slchris/` and the minion config sets this as the ONLY `file_root`. This means you don't need a prefix - just run `qubesctl state.apply debian-minimal.clone` (same approach as qusal).

Features:

*   **Qusal-style patterns**: Uses `slsdotpath`, `clone_template` macro, and `load_yaml` for clean state definitions
*   **Pre-configured templates**: Development, Multimedia, IM, Tools, GPG, Vault, VPN
*   **Pillar-based configuration**: All user settings in one place
*   **Modular design**: Apply only what you need
*   **Reusable macros**: Clone templates, sync appmenus, manage policies

## Installation

See the [detailed installation instructions](docs/install.md).

For a fast local development loop (package on your dev machine → push over the
LAN → deploy to dom0), see the [local development deploy guide](docs/dev-deploy.md).

If template downloads are slow or stall (e.g. far from the ITL CDN), you can
optionally point Qubes at a faster mirror — see the [mirror guide](docs/mirror.md).

### Quick Start

```sh
# 1. Clone in a DomU qube
git clone https://github.com/slchris/qubes-salt-config.git ~/qubes-salt-config

# 2. Copy to Dom0
qube="YOUR_QUBE"
mkdir -p ~/QubesIncoming/"${qube}"
qvm-run --no-gui --pass-io -- "${qube}" "tar -cf - -C ~ qubes-salt-config" | \
  tar -xf - -C ~/QubesIncoming/"${qube}"

# 3. Run setup
cd ~/QubesIncoming/"${qube}"/qubes-salt-config
sudo ./scripts/setup.sh

# 4. Install base templates (REQUIRED FIRST)
sudo qubesctl state.apply debian-minimal.clone
sudo qubesctl state.apply fedora-minimal.clone

# 5. Create base DVM templates
sudo qubesctl state.apply debian-minimal.create
sudo qubesctl state.apply fedora-minimal.create
```

## Templates

| Template | Base | Description | Qubes Created |
|----------|------|-------------|---------------|
| [dev](salt/templates/dev/) | debian-13-minimal | Development environment | tpl-dev, dvm-dev, dev |
| [media](salt/templates/media/) | debian-13-minimal | Multimedia playback | tpl-media, dvm-media |
| [im](salt/templates/im/) | debian-13-minimal | Instant messaging | tpl-im, im |
| [tools](salt/templates/tools/) | debian-13-minimal | General utilities | tpl-tools, dvm-tools |
| [gpg](salt/templates/gpg/) | debian-13-minimal | GPG key management (offline) | tpl-gpg, gpg |
| [vault](salt/templates/vault/) | debian-13-minimal | Password management (offline) | tpl-vault, vault |
| [vpn](salt/templates/vpn/) | fedora-43-minimal | VPN gateway | tpl-vpn, sys-vpn |
| [mcp](salt/templates/mcp/) | debian-13-minimal | MCP server & AI app development | tpl-mcp, dvm-mcp, mcp |
| [gentoo-dev](salt/templates/gentoo-dev/) | gentoo-xfce | Ebuild/package development | tpl-gentoo-dev, gentoo-dev |

**Note:** `gentoo-dev` requires a Gentoo base template, which Qubes does not ship
ready-to-clone. See [salt/gentoo](salt/gentoo/) for how to build it with
qubes-builder before applying `gentoo-dev`.

## Usage

### Create a dev environment

```sh
# Create the dev qubes (in dom0)
sudo qubesctl state.apply templates.dev.create

# Install packages in template
sudo qubesctl --skip-dom0 --targets=tpl-dev state.apply templates.dev.install

# Configure with your dotfiles (optional)
sudo qubesctl --skip-dom0 --targets=dev state.apply templates.dev.configure
```

### Create security qubes (offline)

```sh
# GPG key management (no network)
sudo qubesctl state.apply templates.gpg.create
sudo qubesctl --skip-dom0 --targets=tpl-gpg state.apply templates.gpg.install

# Password vault (no network)
sudo qubesctl state.apply templates.vault.create
sudo qubesctl --skip-dom0 --targets=tpl-vault state.apply templates.vault.install
```

### Create VPN gateway

```sh
sudo qubesctl state.apply templates.vpn.create
sudo qubesctl --skip-dom0 --targets=tpl-vpn state.apply templates.vpn.install
sudo qubesctl --skip-dom0 --targets=sys-vpn state.apply templates.vpn.configure
```

### Common Commands

```sh
# Sync all salt modules
sudo qubesctl saltutil.sync_all

# Refresh pillar data
sudo qubesctl saltutil.refresh_pillar

# Test mode (dry run)
sudo qubesctl state.apply templates.dev.create test=True

# Show pillar data
sudo qubesctl pillar.items

# Package for deployment
./scripts/package.sh v1.0.0
```

## Project Structure

```
salt/
  debian/               # Debian base template
    template.jinja      # Version from pillar
    clone.sls           # Install from repo
  debian-minimal/       # Debian minimal base
    template.jinja      # Version from pillar
    clone.sls           # Install from repo
    create.sls          # Create base DVM
  fedora/               # Fedora base template
    template.jinja      # Version from pillar
    clone.sls           # Install from repo
  fedora-minimal/       # Fedora minimal base
    template.jinja      # Version from pillar
    clone.sls           # Install from repo
    create.sls          # Create base DVM
  templates/            # Pre-configured templates
    dev/                # Development
      clone.sls         # Uses clone_template macro
      create.sls        # Uses slsdotpath and load_yaml
      install.sls       # Package installation
    media/              # Multimedia
    im/                 # Instant messaging
    tools/              # General utilities
    gpg/                # GPG (offline)
    vault/              # Password (offline)
    vpn/                # VPN gateway
  utils/
    macros/
      clone-template.sls  # Template cloning macro
      update-admin.sls    # Admin VM update macro
      sync-appmenus.sls   # Appmenu sync macro
      policy.sls          # RPC policy macros
  dotfiles/             # User dotfiles
pillar/
  top.sls               # Pillar top file
  user.sls              # User configuration
scripts/
  setup.sh              # Setup script for dom0
  package.sh            # Package for deployment
  qubes-mirror.sh       # Optional: point Qubes at a download mirror
  lint.sh               # Run yamllint + salt-lint locally
  check_top_pairing.py  # Enforce .sls <-> .top pairing
docs/
  install.md            # Detailed installation guide
  dev-deploy.md         # Local dev loop: package -> LAN -> dom0
  mirror.md             # Optional download mirror (TUNA / kernel.org)
  remote-debug.md       # SSH-driven debugging via a jump qube
```

## Key Concepts (from qusal)

### slsdotpath Variable

All state files use `slsdotpath` to reference themselves dynamically:

```salt
include:
  - {{ slsdotpath }}.clone

{% load_yaml as defaults -%}
name: tpl-{{ slsdotpath }}
...
```

### clone_template Macro

Simplifies template cloning with the `clone_template` macro:

```salt
{% from 'utils/macros/clone-template.sls' import clone_template -%}
{{ clone_template('debian-minimal', sls_path) }}
```

### load_yaml Pattern

Uses `load_yaml` and `qvm/template.jinja` for clean qube definitions:

```salt
{%- from "qvm/template.jinja" import load -%}

{% load_yaml as defaults -%}
name: tpl-{{ slsdotpath }}
force: True
require:
- sls: {{ slsdotpath }}.clone
prefs:
- label: green
- memory: 400
{%- endload %}
{{ load(defaults) }}
```

## Template Upgrade

Template versions are configured via pillar (`pillar/user.sls`):

```yaml
qvm:
  debian:
    version: "13"         # Change to upgrade (e.g., "14")
  fedora:
    version: "43"         # Change to upgrade (e.g., "44")
```

After changing versions:

1.  Rename existing templates in Qube Manager (add `-old` suffix)
2.  Refresh pillar: `sudo qubesctl saltutil.refresh_pillar`
3.  Rerun formulas: `sudo qubesctl state.apply templates.dev.create`

See [Template Upgrade Guide](docs/install.md#template-upgrade) for details.

## Credits

This project is based on patterns from [qusal](https://github.com/ben-grande/qusal) by Benjamin Grande and the Qubes OS SaltStack community.

Project repository: [github.com/slchris/qubes-salt-config](https://github.com/slchris/qubes-salt-config)

## License

SPDX-License-Identifier: MIT

Copyright 2026 Chris Su
