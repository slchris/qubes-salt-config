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

### Split GPG 2 and Split SSH

Clients come from `cfg.profiles`. Each profile's project AppVM and pass
qube may use that profile's gpg qube, and no other gpg qube. Private keys
stay in the offline gpg qube. The `slchris` profile uses the CanoKey in
the `gpg` qube. The YubiKey on this host belongs to another profile's qube,
which is not named here and is not attached to `gpg`. The template already
runs `pcscd`.
`scdaemon.conf` sets `disable-ccid` and `pcsc-shared`, because the
CanoKey's OpenPGP interface is not interface 0. `templates.gpg.pcscd`
lets the qube user talk to pcscd when the session is not a seat.
Split SSH offers only the CanoKey authentication subkey.
Do not copy secret keys into the client.

`qubes.Gpg2` is allowed. split-gpg2 refuses to export key material.
`qubes.SshAgent` is allowed for that profile's project AppVM only. The
pass qube does not get an SSH agent. The project AppVM is headless;
the card PIN is cached in the gpg qube, and the private key stays there.
Apt for `tpl-gpg` goes through
`sys-bwg-net` (`cfg.agents.updates_proxy.templates`).

```sh
# VPN gateway up, then the two templates. Shut the gateway afterwards.
sudo qubesctl state.apply agents.updates-proxy
sudo qubesctl --skip-dom0 --targets=tpl-gpg state.apply templates.gpg.split
sudo qubesctl --skip-dom0 --targets=tpl-agents state.apply agents.template.split
qvm-shutdown --wait tpl-gpg tpl-agents

sudo qubesctl state.apply templates.gpg.policy
sudo qubesctl --skip-dom0 --targets=gpg state.apply templates.gpg.configure
sudo qubesctl --skip-dom0 --targets=slchris-project state.apply agents.split
sudo qubesctl --skip-dom0 --targets=slchris-project state.apply dotfiles.git
# restart slchris-project so split-gpg2-client replaces its gpg-agent
```

`templates.gpg.install` also lists these packages, but it runs `pkg.uptodate`.
Use `templates.gpg.split` and `agents.template.split` to add only this stack.

### Generate a new key

```sh
qvm-run -u user gpg -- gpg --full-generate-key
```

### Import an existing public key

`files/chris-su.asc` is the YubiKey-backed Veritas key. It is not the
CanoKey and it is not imported here. To import a public key:

```sh
qvm-copy-to-vm gpg /path/to/public-key.asc
qvm-run -u user gpg -- gpg --import /home/user/QubesIncoming/*/public-key.asc
```

## Qubes Created

| Qube | Type | Description |
|------|------|-------------|
| tpl-gpg | Template | Base template with GPG packages |
| gpg | AppVM | Offline qube for key storage |

## License

SPDX-License-Identifier: MIT

Copyright 2026 Chris Su
