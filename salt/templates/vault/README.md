# Vault

Offline password management template for Qubes OS.

## Table of Contents

*   [Description](#description)
*   [Installation](#installation)
*   [Usage](#usage)

## Description

Creates an offline vault qube for password management with KeePassXC and pass. This qube has no network access for maximum security.

Packages installed:

*   keepassxc - Cross-platform password manager
*   pass - Standard Unix password manager
*   pwgen - Password generator
*   qtpass - Qt GUI for pass
*   xclip - Clipboard utility

## Installation

### Using Top File (Recommended)

```sh
sudo qubesctl top.enable templates.vault
sudo qubesctl --targets=tpl-vault state.apply
sudo qubesctl top.disable templates.vault
```

### Using State Directly

```sh
# Create the vault qube
sudo qubesctl state.apply templates.vault.create

# Install packages
sudo qubesctl --skip-dom0 --targets=tpl-vault state.apply templates.vault.install

# Configure (optional)
sudo qubesctl --skip-dom0 --targets=vault state.apply templates.vault.configure
```

## Usage

### KeePassXC

1.  Create a new database in the vault qube
2.  Store the database file in `/home/user/`
3.  Use Qubes clipboard to copy passwords to other qubes

### pass (Standard Unix Password Manager)

```sh
# Initialize password store (requires GPG key)
pass init <gpg-key-id>

# Add a password
pass insert email/personal

# Generate a password
pass generate web/github 20

# Copy password to clipboard
pass -c email/personal
```

### Split Password Store

For enhanced security, combine with split-GPG:

1.  Store GPG keys in the `gpg` qube
2.  Use `pass` in `vault` qube with split-GPG
3.  Passwords are encrypted with keys stored separately

## Qubes Created

| Qube | Type | Description |
|------|------|-------------|
| tpl-vault | Template | Base template with password tools |
| vault | AppVM | Offline qube for password storage |

## License

SPDX-License-Identifier: MIT

Copyright 2026 Chris Su
