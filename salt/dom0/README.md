# dom0

Dom0 management states for Qubes OS.

## Table of Contents

*   [Description](#description)
*   [States](#states)
*   [Usage](#usage)

## Description

States that run in dom0 to manage system-wide settings and install base templates.

## States

| State | Description |
|-------|-------------|
| install-templates | Install required base templates (fedora-42, debian-13) |

## Usage

### Install Base Templates

Before creating any custom templates, install the required base templates:

```sh
# Check and install if needed
qvm-check fedora-42-minimal || sudo qubes-dom0-update qubes-template-fedora-42-minimal
qvm-check debian-13 || sudo qubes-dom0-update qubes-template-debian-13
```

This will install:

*   `fedora-42-minimal` - For management (mgmt) and VPN
*   `debian-13-minimal` - For lightweight templates
*   `debian-13` - For full desktop templates
*   `fedora-42` - For network-related templates

## License

SPDX-License-Identifier: MIT

Copyright 2026 Chris Su
