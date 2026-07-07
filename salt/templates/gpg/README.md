# GPG

GPG/GnuPG template for Qubes OS.

## Table of Contents

*   [Description](#description)
*   [Installation](#installation)
*   [Usage](#usage)

## Description

Creates a GPG template qube with GnuPG and related tools for cryptographic operations. This template is designed for split-GPG setups in Qubes OS.

Packages installed:

*   gnupg2 - GNU Privacy Guard
*   pinentry-gtk - PIN entry dialog for GTK
*   sequoia-sq - Modern PGP implementation
*   pcsc-lite - Smart card daemon
*   hopenpgp-tools - OpenPGP key analysis tools

## Installation

### Using Top File (Recommended)

```sh
sudo qubesctl top.enable templates.gpg
sudo qubesctl --targets=tpl-gpg state.apply
sudo qubesctl top.disable templates.gpg
```

### Using State Directly

```sh
# Create the GPG qube
sudo qubesctl state.apply templates.gpg.create

# Install packages
sudo qubesctl --skip-dom0 --targets=tpl-gpg state.apply templates.gpg.install

# Configure (optional)
sudo qubesctl --skip-dom0 --targets=gpg state.apply templates.gpg.configure
```

## Usage

### Split-GPG Setup

For enhanced security, use split-GPG:

1.  Store GPG keys in the `gpg` qube (offline)
2.  Client qubes request signing/decryption via Qubes RPC
3.  User confirms each operation

### Generate a new key

```sh
qvm-run -u user gpg -- gpg --full-generate-key
```

### Import existing key

```sh
qvm-copy-to-vm gpg /path/to/secret-key.asc
qvm-run -u user gpg -- gpg --import /home/user/QubesIncoming/*/secret-key.asc
```

## Qubes Created

| Qube | Type | Description |
|------|------|-------------|
| tpl-gpg | Template | Base template with GPG packages |
| gpg | AppVM | Offline qube for key storage |

## License

SPDX-License-Identifier: MIT

Copyright 2026 Chris Su
