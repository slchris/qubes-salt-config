# Install

qubes-salt-config install and update guide.

## Table of Contents

*   [Installation](#installation)
    *   [Prerequisites](#prerequisites)
    *   [DomU Installation](#domu-installation)
    *   [Dom0 Installation](#dom0-installation)
*   [First Run: Setup Management](#first-run-setup-management)
*   [Configuration](#configuration)
*   [Using Templates](#using-templates)
*   [Update](#update)
    *   [DomU Update](#domu-update)
    *   [Dom0 Update](#dom0-update)
*   [Packaging](#packaging)
*   [Template Upgrade](#template-upgrade)
    *   [Clean Install (Recommended)](#clean-install-recommended)
    *   [Upgrade In-Place](#upgrade-in-place)
*   [Troubleshooting](#troubleshooting)

## Installation

### Prerequisites

Your current setup needs to fulfill the following requirements:

*   Qubes OS R4.3 (R4.2 reached end of life on 2026-06-21)
*   Internet connection
*   A qube with `git` installed for downloading

### DomU Installation

It is recommended to use a separate qube from your normal operations as this installation will eventually be copied to dom0. Use a DispVM, AppVM, or StandaloneVM.

1.  Install `git` in the qube. If using an AppVM, install it in the TemplateVM and restart the AppVM:

    ```sh
    # In TemplateVM (e.g., debian-13 or fedora-43)
    # Debian:
    sudo apt install git
    # Fedora:
    sudo dnf install git
    ```

2.  Clone the repository:

    ```sh
    git clone https://github.com/slchris/qubes-salt-config.git ~/qubes-salt-config
    ```

3.  Verify the repository contents:

    ```sh
    ls ~/qubes-salt-config
    ```

    You should see:
    ```
    docs/  readme.md  scripts/  salt/  minion.d/
    ```

### Dom0 Installation

Before copying anything to Dom0, read the [Qubes OS warning about copying to dom0](https://www.qubes-os.org/doc/how-to-copy-from-dom0/#copying-to-dom0).

1.  Copy the repository from the DomU to Dom0. Replace `QUBE` with the name of your qube:

    ```sh
    qube="QUBE"  # Change this to your qube name
    
    mkdir -p ~/QubesIncoming/"${qube}"
    qvm-run --no-gui --pass-io -- "${qube}" "tar -cf - -C ~ qubes-salt-config" | \
      tar -xf - -C ~/QubesIncoming/"${qube}"
    ```

2.  Enter the repository directory:

    ```sh
    cd ~/QubesIncoming/"${qube}"/qubes-salt-config
    ```

3.  Run the setup script:

    ```sh
    sudo ./scripts/setup.sh
    ```

    This script will:
    *   Install minion configuration to `/etc/salt/minion.d/`
    *   Create `/srv/salt/slchris` and copy all salt files (config lives in
        `salt/config.jinja` — this project uses no pillar)
    *   Remove any old `/srv/pillar/slchris` from earlier versions
    *   Sync salt modules (`saltutil.sync_all`)

## First Run: Setup Management

**IMPORTANT**: Before using any other templates, you must first set up the management environment. This is required for salt operations on DomU qubes.

### Step 1: Install Base Templates

Ensure base templates are available. Install if not present:

```sh
# Check and install fedora-43-minimal for mgmt
qvm-check fedora-43-minimal || sudo qubes-dom0-update qubes-template-fedora-43-minimal

# Check and install debian-13 for other templates (optional)
qvm-check debian-13 || sudo qubes-dom0-update qubes-template-debian-13
```

> If a template download is very slow or appears to hang, the ITL source may be
> unreachable from your location. See the [mirror guide](mirror.md) to point
> Qubes at a faster mirror (opt-in).

### Step 2: Create Management Environment

Using top.enable (recommended):

```sh
sudo qubesctl top.enable mgmt
sudo qubesctl --targets=tpl-mgmt state.apply
sudo qubesctl top.disable mgmt
sudo qubesctl state.apply mgmt.prefs
```

Or using state directly:

```sh
# Create tpl-mgmt and dvm-mgmt
sudo qubesctl state.apply mgmt.create

# Install packages in tpl-mgmt
sudo qubesctl --skip-dom0 --targets=tpl-mgmt state.apply mgmt.install

# Set dvm-mgmt as default management_dispvm
sudo qubesctl state.apply mgmt.prefs
```

After this, you can run salt states on any DomU qube.

## Configuration

All user configuration lives in `salt/config.jinja` (this project uses **no**
Salt pillar). On the machine it is at `/srv/salt/slchris/config.jinja`:

```sh
sudo vim /srv/salt/slchris/config.jinja
```

It is a Jinja dict keyed under `cfg`. Set your personal information, e.g.:

```jinja
"user": {
  "shell": {"default": "bash", "timezone": "Asia/Shanghai", "locale": "en_US.UTF-8"},
},
"qubes": {
  "dev": {"git": {"name": "Your Name", "email": "you@example.com"}},
},
```

Changes take effect on the next `state.apply` — there is no pillar to refresh.

## Using Templates

### Template Overview

| Template | Base | Description |
|----------|------|-------------|
| dev | debian-13 | Development (VS Code, Go, Python) |
| media | debian-13 | Multimedia (mpv, VLC, ffmpeg) |
| im | debian-13 | Instant Messaging (Weechat, Telegram) |
| tools | debian-13 | Office (GIMP, LibreOffice) |
| gpg | debian-13 | GPG key management |
| vault | debian-13 | Password management (KeePassXC, pass) |
| vpn | fedora-43 | VPN gateway (WireGuard, OpenVPN) |

### Create a Template (Example: dev)

Using top.enable (recommended):

```sh
sudo qubesctl top.enable templates.dev
sudo qubesctl --targets=tpl-dev state.apply
sudo qubesctl top.disable templates.dev

# Configure (optional)
sudo qubesctl --skip-dom0 --targets=dev state.apply templates.dev.configure
```

Or using state directly:

```sh
# Create the qubes
sudo qubesctl state.apply templates.dev.create

# Install packages
sudo qubesctl --skip-dom0 --targets=tpl-dev state.apply templates.dev.install

# Configure (optional)
sudo qubesctl --skip-dom0 --targets=dev state.apply templates.dev.configure
```

### Create Security Qubes (Offline)

```sh
# GPG (offline key management)
sudo qubesctl top.enable templates.gpg
sudo qubesctl --targets=tpl-gpg state.apply
sudo qubesctl top.disable templates.gpg

# Vault (offline password manager)
sudo qubesctl top.enable templates.vault
sudo qubesctl --targets=tpl-vault state.apply
sudo qubesctl top.disable templates.vault
```

### Create VPN Gateway

```sh
sudo qubesctl top.enable templates.vpn
sudo qubesctl --targets=tpl-vpn state.apply
sudo qubesctl top.disable templates.vpn
sudo qubesctl --skip-dom0 --targets=sys-vpn state.apply templates.vpn.configure
```

## Update

### DomU Update

Update the repository in your DomU:

```sh
cd ~/qubes-salt-config
git pull
```

### Dom0 Update

1.  Update in DomU first (see above).

2.  Copy to Dom0:

    ```sh
    qube="QUBE"
    rm -rf ~/QubesIncoming/"${qube}"/qubes-salt-config
    qvm-run --no-gui --pass-io -- "${qube}" "tar -cf - -C ~ qubes-salt-config" | \
      tar -xf - -C ~/QubesIncoming/"${qube}"
    ```

3.  Run setup:

    ```sh
    cd ~/QubesIncoming/"${qube}"/qubes-salt-config
    sudo ./scripts/setup.sh
    ```

## Packaging

Create a tarball for deploying to new machines. For an iterative dev loop that
pushes your working copy over the LAN instead, see
[dev-deploy.md](dev-deploy.md).

### Create Package

```sh
# In the project directory
./scripts/package.sh

# Or with a version
./scripts/package.sh v1.0.0
```

This creates:
*   `dist/qubes-salt-config-VERSION.tar.gz`
*   `dist/qubes-salt-config-VERSION.tar.gz.sha256`

### Deploy Package

1.  Copy the tarball to a qube with network access
2.  Extract: `tar -xzf qubes-salt-config-*.tar.gz`
3.  Copy to dom0 (see Dom0 Installation above)
4.  Run `sudo ./scripts/setup.sh`

## Template Upgrade

Template upgrade refers to major version upgrades (e.g., debian-13 → debian-14, fedora-43 → fedora-44).

The template version is controlled in `config.jinja`. To upgrade templates:

1.  Edit `config.jinja` in dom0:

    ```sh
    sudo vim /srv/salt/slchris/config.jinja
    ```

2.  Update the version numbers under `cfg.qvm`:

    ```jinja
    "qvm": {
      "debian": {"version": "14", "repo": "qubes-templates-itl"},
      "fedora": {"version": "44", "repo": "qubes-templates-itl"},
      ...
    },
    ```

3.  Re-apply the affected states (no pillar refresh needed):

    ```sh
    sudo qubesctl state.apply debian-minimal.create
    ```

### Clean Install (Recommended)

As we use Salt, doing clean installs is easy. This method ensures a fresh environment matching upstream template builds.

1.  Open `Qube Manager`, select the template you want to upgrade (e.g., `tpl-dev`) and rename it adding the suffix `-old` (e.g., `tpl-dev-old`). The `Qube Manager` will change the `template` preference of qubes based on the chosen template.

2.  Rerun the formulas that targeted the chosen template:

    ```sh
    # Using top.enable (recommended)
    sudo qubesctl top.enable templates.dev
    sudo qubesctl --targets=tpl-dev state.apply
    sudo qubesctl top.disable templates.dev
    ```

3.  If the formula fails, use `Qube Manager` or `Qubes Template Switcher` to set the `-old` template to be used by the qubes managed by that specific formula.

4.  Test the new template thoroughly.

5.  When satisfied, remove the old template:

    ```sh
    qvm-remove tpl-dev-old
    ```

6.  Repeat for every template that needs to be upgraded.

### Upgrade In-Place

This method is **discouraged** as it leads to different results compared to installing a new template. Fixes done upstream by Qubes OS to the build system of templates, such as package lists, cannot be backported to old templates.

One advantage of this method is when dealing with a StandaloneVM, as important data can be present in the root volume. In-place upgrades are easier for this qube class instead of migrating specific folders and files to the new qube.

1.  If you still want to do upgrade in-place, refer to upstream guides:
    *   [Debian in-place upgrade](https://www.qubes-os.org/doc/templates/debian/in-place-upgrade)
    *   [Fedora in-place upgrade](https://www.qubes-os.org/doc/templates/fedora/in-place-upgrade)

2.  Rerun the formulas that targeted the chosen template:

    ```sh
    sudo qubesctl --skip-dom0 --targets=tpl-dev state.apply templates.dev.install
    ```

3.  Repeat for every template that needs to be upgraded.

## Troubleshooting

### "Template not found" Error

Ensure base templates are installed:

```sh
# List templates
qvm-ls --templates

# Install missing template
sudo qubes-dom0-update qubes-template-debian-13
```

### Salt Errors on DomU

Ensure mgmt is set up:

```sh
# Check management_dispvm
qubes-prefs management_dispvm

# Should show: dvm-mgmt
```

### Config Not Applied

This project uses no pillar; config is in `salt/config.jinja`, read directly by
states. If a config change had no effect:

```sh
# Confirm the deployed config exists and has your value
ls /srv/salt/slchris/config.jinja
grep -n 'enabled\|version' /srv/salt/slchris/config.jinja

# Re-sync modules and re-apply the state (config.jinja is read at apply time)
sudo qubesctl saltutil.sync_all
```

If the value on disk is stale, re-deploy the repo (`setup.sh`) — editing the
source does not update `/srv/salt/slchris` until you run setup again.

### Package Installation Fails

Check network connectivity in the template:

```sh
# Temporarily enable network for template
qvm-prefs tpl-dev netvm sys-firewall
qvm-run tpl-dev 'ping -c 1 google.com'
```

## Quick Reference

```sh
# Complete setup from scratch
sudo ./scripts/setup.sh

# Setup management
sudo qubesctl top.enable mgmt
sudo qubesctl --targets=tpl-mgmt state.apply
sudo qubesctl top.disable mgmt
sudo qubesctl state.apply mgmt.prefs

# Then create any template (e.g., dev)
sudo qubesctl top.enable templates.dev
sudo qubesctl --targets=tpl-dev state.apply
sudo qubesctl top.disable templates.dev
```

## License

SPDX-License-Identifier: MIT

Copyright 2026 Chris Su
