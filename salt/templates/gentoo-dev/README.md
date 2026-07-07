# tpl-gentoo-dev

Gentoo ebuild / package development environment for Qubes OS.

## Table of Contents

*   [Description](#description)
*   [Prerequisites](#prerequisites)
*   [Installation](#installation)
*   [Packages](#packages)
*   [Usage](#usage)

## Description

Creates a Gentoo-based environment for writing, testing and maintaining ebuilds
and overlays:

| Qube | Type | Description |
|------|------|-------------|
| tpl-gentoo-dev | Template | Cloned from the Gentoo base template, with ebuild tooling |
| gentoo-dev | AppVM | Persistent workspace with a local overlay configured |

The template is **networked** so `emerge` can fetch distfiles, and the qubes get
extra vcpus/memory because Gentoo compiles from source.

## Prerequisites

This formula clones from a **Gentoo base template** (`gentoo-xfce` by default),
which Qubes does not ship ready-to-clone. Set up the base template first — see
[salt/gentoo](../../gentoo/README.md) for how to build it with `qubes-builder`
or install it from a community repo.

```sh
sudo qubesctl state.apply gentoo.clone   # verifies / installs the base template
sudo qubesctl state.apply gentoo.create  # optional base DVM
```

## Installation

### Using Top File (Recommended)

```sh
sudo qubesctl top.enable templates.gentoo-dev
sudo qubesctl --targets=tpl-gentoo-dev state.apply
sudo qubesctl top.disable templates.gentoo-dev
```

### Using State Directly

```sh
# Step 1: Create qubes (in dom0)
sudo qubesctl state.apply templates.gentoo-dev.create

# Step 2: Install ebuild tooling in the template (long: emerge builds from source)
sudo qubesctl --skip-dom0 --targets=tpl-gentoo-dev state.apply templates.gentoo-dev.install

# Step 3: Configure the workspace (local overlay + repos.conf)
sudo qubesctl --skip-dom0 --targets=gentoo-dev state.apply templates.gentoo-dev.configure
```

## Packages

Installed via Portage atoms in `tpl-gentoo-dev`:

| Atom | Description |
|------|-------------|
| `dev-vcs/git` | Version control |
| `app-portage/gentoolkit` | `equery`, `euse`, `revdep-rebuild` |
| `app-portage/eix` | Fast package search/index |
| `app-portage/portage-utils` | `qatom`, `qlist`, `qmerge` |
| `app-portage/repoman` | Ebuild QA / policy checker |
| `app-portage/pkgcheck` | Modern ebuild linter |
| `app-portage/flaggie` | USE-flag management |
| `app-portage/layman` | Overlay management |
| `app-eselect/eselect-repository` | Add/manage ebuild repositories |
| `app-editors/vim`, `app-editors/neovim` | Editors |
| `app-misc/tmux`, `sys-process/htop`, `app-misc/jq`, `sys-apps/ripgrep` | Utilities |

## Usage

The `configure` step registers a personal overlay at `/home/user/overlay`
(repository id `localdev`) in the `gentoo-dev` qube.

```sh
# Create a new ebuild in your overlay
qvm-run gentoo-dev 'mkdir -p ~/overlay/app-misc/hello/files'

# QA-check an ebuild
qvm-run gentoo-dev 'cd ~/overlay && pkgcheck scan app-misc/hello'

# Test-install from your overlay
qvm-run gentoo-dev 'sudo emerge --ask localdev/hello'
```
