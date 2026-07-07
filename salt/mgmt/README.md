# mgmt

Management environment for Salt operations in Qubes OS.

## Table of Contents

*   [Description](#description)
*   [Installation](#installation)
*   [Usage](#usage)

## Description

This module creates a management DispVM template (dvm-mgmt) that is used for:

*   Running salt states on DomU qubes
*   Opening disposable consoles
*   Salt management operations

The management qube uses `fedora-42-minimal` as its base template for a lightweight footprint.

## Prerequisites

The full Fedora template (`fedora-42`) is required as bootstrap because it has polkit 
configured for passwordless sudo. The minimal template does not have this.

## Installation

### Bootstrap (first time only)

```sh
# Create default-mgmt-dvm for initial bootstrap
sudo qubesctl state.sls qvm.default-mgmt-dvm

# Create fedora (full) template and dvm - needed for polkit/sudo
sudo qubesctl state.apply fedora.create
sudo qubesctl --skip-dom0 --targets=fedora-42 state.apply fedora.install

# Create fedora-minimal template (uses dvm-fedora for management)
sudo qubesctl state.apply fedora-minimal.create
sudo qubesctl --skip-dom0 --targets=fedora-42-minimal state.apply fedora-minimal.install
```

### Install mgmt

```sh
# Create tpl-mgmt and dvm-mgmt (uses dvm-fedora for bootstrap)
sudo qubesctl state.apply mgmt.create

# Install salt packages in tpl-mgmt
sudo qubesctl --skip-dom0 --targets=tpl-mgmt state.apply mgmt.install

# Set dvm-mgmt as global management_dispvm and cleanup
sudo qubesctl state.apply mgmt.prefs

# Optional: Set fedora templates to use default management_dispvm
sudo qubesctl state.apply fedora.prefs
sudo qubesctl state.apply fedora-minimal.prefs
```

## Qubes Created

| Qube | Type | Description |
|------|------|-------------|
| tpl-mgmt | Template | Base template (from fedora-42-minimal) |
| dvm-mgmt | DispVM Template | Management DispVM for salt operations |

## Usage

After installation, dvm-mgmt becomes the default `management_dispvm`. It is used automatically when:

*   Running `qubesctl --targets=QUBE state.apply STATE` on DomU qubes
*   Opening a disposable console with `qvm-console-dispvm`

## License

SPDX-License-Identifier: MIT

Copyright 2026 Chris Su
