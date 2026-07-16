# templates

Pre-configured templates for Qubes OS.

## Table of Contents

*   [Description](#description)
*   [Prerequisites](#prerequisites)
*   [Available Templates](#available-templates)
*   [Installation](#installation)

## Description

This directory contains pre-configured templates for different use cases.
Each template creates:

*   A template qube (tpl-*) with pre-installed packages
*   An AppVM for persistent work
*   A DispVM template (dvm-*) for disposable sessions (when applicable)

## Prerequisites

Before using any template, ensure:

1.  Management environment is set up:
    ```sh
    sudo qubesctl top.enable mgmt
    sudo qubesctl --targets=tpl-mgmt state.apply
    sudo qubesctl top.disable mgmt
    sudo qubesctl state.apply mgmt.prefs
    ```

## Available Templates

### Debian-based (debian-13)

| Template | Description | Qubes Created |
|----------|-------------|---------------|
| [dev](dev/) | Development environment | tpl-dev, dvm-dev, dev |
| [media](media/) | Multimedia (video/audio) | tpl-media, dvm-media, media |
| [im](im/) | Instant Messaging | tpl-im, im |
| [tools](tools/) | Office/Productivity | tpl-tools, dvm-tools, work |
| [gpg](gpg/) | GPG key management (offline) | tpl-gpg, gpg |
| [vault](vault/) | Password management (offline) | tpl-vault, vault |
| [mcp](mcp/) | MCP server & AI app development | tpl-mcp, dvm-mcp, mcp |
| [project-net](project-net/) | Per-project WireGuard gateway (fail-closed) | tpl-project-net, sys-project-net |
| [ai](ai/) | Claude Desktop + agents behind project VPN | tpl-ai, dvm-ai, ai |

### Fedora-based (fedora-43)

| Template | Description | Qubes Created |
|----------|-------------|---------------|
| [vpn](vpn/) | VPN gateway | tpl-vpn, sys-vpn |

## Installation

### Using Top File (Recommended)

```sh
# Example: Install dev template
sudo qubesctl top.enable templates.dev
sudo qubesctl --targets=tpl-dev state.apply
sudo qubesctl top.disable templates.dev
```

### Using State Directly

```sh
# Create all templates
sudo qubesctl state.apply templates.dev.create
sudo qubesctl state.apply templates.media.create
sudo qubesctl state.apply templates.im.create
sudo qubesctl state.apply templates.tools.create
sudo qubesctl state.apply templates.gpg.create
sudo qubesctl state.apply templates.vault.create
sudo qubesctl state.apply templates.vpn.create

# Install packages (Debian-based)
sudo qubesctl --skip-dom0 --targets=tpl-dev state.apply templates.dev.install
sudo qubesctl --skip-dom0 --targets=tpl-media state.apply templates.media.install
sudo qubesctl --skip-dom0 --targets=tpl-im state.apply templates.im.install
sudo qubesctl --skip-dom0 --targets=tpl-tools state.apply templates.tools.install
sudo qubesctl --skip-dom0 --targets=tpl-gpg state.apply templates.gpg.install
sudo qubesctl --skip-dom0 --targets=tpl-vault state.apply templates.vault.install

# Install packages (Fedora-based)
sudo qubesctl --skip-dom0 --targets=tpl-vpn state.apply templates.vpn.install
```

### Install Individual Template

See the README.md in each template directory for specific instructions.

## License

SPDX-License-Identifier: MIT

Copyright 2026 Chris Su
