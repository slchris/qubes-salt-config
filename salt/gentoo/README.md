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

*   installs the template from a repo **only if** you set `cfg.qvm.gentoo.repo`
    in config.jinja, and
*   otherwise **verifies the template already exists** and fails with build
    instructions if it does not.

This formula never fabricates a Gentoo template — it will not silently succeed
if no Gentoo template is present.

## Obtaining the Gentoo template

### Option A — Build with qubes-builderv2 (source of truth)

There is no qusal / community Salt formula that builds a Gentoo template — the
only upstream path is Qubes' own build system. It is driven by three official
components:

*   [qubes-builderv2](https://github.com/QubesOS/qubes-builderv2) — the build
    orchestrator (the `./qb` tool). Ships `example-configs/gentoo.yml`.
*   [qubes-builder-gentoo](https://github.com/QubesOS/qubes-builder-gentoo) —
    the Gentoo plugin: it downloads the **latest systemd stage3** from
    `distfiles.gentoo.org`, GPG- and SHA512-verifies it, extracts it into a
    chroot, syncs Portage, then emerges the package lists per flavor.
*   [qubes-gentoo](https://github.com/QubesOS/qubes-gentoo) — the Qubes **ebuild
    overlay** (qubes-core-agent etc.), selected per Qubes release by Git branch.

So the base is **not** an existing template you clone — it is bootstrapped from a
Gentoo stage3 tarball and compiled from source. Flavors produced:
`gentoo` (gnome), `gentoo-minimal`, `gentoo-xfce`.

> **Note:** This compiles everything from source. Upstream sets a per-template
> `timeout: 86400` (24h) and a 30 GB root — plan for **many hours** on capable
> hardware.

Steps (run in a dedicated Fedora/Debian build qube, not dom0):

```sh
# 1. Get qubes-builderv2 and its dependencies (see its README for the full
#    dependency install; it uses a Docker/podman executor by default).
git clone https://github.com/QubesOS/qubes-builderv2 ~/qubes-builderv2
cd ~/qubes-builderv2

# 2. Use the official Gentoo config as a starting point.
cp example-configs/gentoo.yml builder.yml
#   Edit builder.yml: set `qubes-release` (e.g. r4.3) and keep only the
#   flavor(s) you want under `templates:` (gentoo / gentoo-minimal / gentoo-xfce).

# 3. Build one template (repeat per flavor). This is the long step.
./qb --builder-conf builder.yml -c builder-gentoo package fetch
./qb --builder-conf builder.yml template all
#   The template .rpm lands under ~/qubes-builderv2/artifacts/templates/

# 4. Move the resulting .rpm into dom0 and install it. From dom0:
#   qvm-run --pass-io <build-qube> \
#     'cat ~/qubes-builderv2/artifacts/templates/qubes-template-gentoo-xfce-*.rpm' \
#     > /tmp/gentoo-xfce.rpm
#   sudo qubes-dom0-update --action=install /tmp/gentoo-xfce.rpm
```

The exact `./qb` stages and flags change between builderv2 versions — always
cross-check the current
[qubes-builderv2 README](https://github.com/QubesOS/qubes-builderv2) and
`example-configs/gentoo.yml`.

### Option B — Community repository

If a community repo provides a prebuilt Gentoo template, set it in config.jinja and
let `gentoo.clone` install it:

```jinja
# salt/config.jinja — under cfg.qvm
"gentoo": {
  "flavor": "xfce",          # gentoo-xfce (or "" for gentoo, "minimal" for gentoo-minimal)
  "repo": "qubes-templates-community",
},
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

| Config key (config.jinja)  | Default | Description                                        |
|----------------------------|---------|----------------------------------------------------|
| `cfg.qvm.gentoo.flavor`    | `xfce`  | Template flavor: `xfce`, `` (gnome), or `minimal`. |
| `cfg.qvm.gentoo.repo`      | (unset) | If set, install the template from this dom0 repo.  |
