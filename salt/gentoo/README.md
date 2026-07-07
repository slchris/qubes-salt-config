# gentoo

Gentoo base template support for Qubes OS.

## Table of Contents

*   [Description](#description)
*   [Obtaining the Gentoo template](#obtaining-the-gentoo-template)
*   [Usage](#usage)
*   [Configuration](#configuration)

## Description

This formula manages a **Gentoo base template** so that other formulas (such as
[gentoo-dev](../templates/gentoo-dev/)) can derive from it.

Unlike Debian and Fedora, **Qubes OS does not ship a ready-to-clone Gentoo
template** in the default ITL repositories. Gentoo is a source-based rolling
distribution; the template must be built from source with `qubes-builder`, or
installed from a community repository when one is available. As of 2026 the
prebuilt `gentoo-minimal` was removed from the Template Manager.

Because of this, `gentoo.clone`:

*   installs the template from a repo **only if** you set `qvm:gentoo:repo` in
    pillar, and
*   otherwise **verifies the template already exists** and fails with build
    instructions if it does not.

This formula never fabricates a Gentoo template — it will not silently succeed
if no Gentoo template is present.

## Obtaining the Gentoo template

### Option A — Build with qubes-builder (source of truth)

Gentoo templates are built from the official
[qubes-template-configs](https://github.com/QubesOS/qubes-template-configs) and
[qubes-gentoo](https://github.com/QubesOS/qubes-gentoo) repositories.

> **Note:** Building a Gentoo template compiles everything from source and can
> take **half a day or more** per template. Do this on capable hardware.

High-level steps (run in a dedicated build qube, not dom0):

```sh
# In a Fedora/Debian build qube with qubes-builder installed:
git clone https://github.com/QubesOS/qubes-builderv2 ~/qubes-builderv2
cd ~/qubes-builderv2

# Use a Gentoo template config (flavor: gentoo-xfce / gentoo / gentoo-minimal)
# from qubes-template-configs as your builder.conf, then:
./qb --template-name gentoo-xfce template build

# Copy the resulting template RPM into dom0 and install it:
#   qvm-run --pass-io <build-qube> 'cat <path-to>.rpm' > gentoo-xfce.rpm
#   sudo qubes-dom0-update --action=install ./gentoo-xfce.rpm
```

Refer to the official Qubes template-building documentation for the exact,
up-to-date invocation, as builder flags change between versions.

### Option B — Community repository

If a community repo provides a prebuilt Gentoo template, set it in pillar and
let `gentoo.clone` install it:

```yaml
# pillar/user.sls
qvm:
  gentoo:
    flavor: "xfce"          # gentoo-xfce  (or "" for gentoo, "minimal" for gentoo-minimal)
    repo: "qubes-templates-community"
```

## Usage

Once a Gentoo template (e.g. `gentoo-xfce`) is installed:

```sh
# Verify / (optionally) install the template, then create the base DVM
sudo qubesctl state.apply gentoo.clone
sudo qubesctl state.apply gentoo.create
```

Then build a usable environment on top with the
[gentoo-dev](../templates/gentoo-dev/) formula.

## Configuration

| Pillar key           | Default | Description                                             |
|----------------------|---------|---------------------------------------------------------|
| `qvm:gentoo:flavor`  | `xfce`  | Template flavor: `xfce`, `` (gnome), or `minimal`.      |
| `qvm:gentoo:repo`    | (unset) | If set, install the template from this dom0 repo.       |
