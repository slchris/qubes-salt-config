# gentoo

Gentoo base template support for Qubes OS.

## Table of Contents

*   [Description](#description)
*   [Obtaining the Gentoo template](#obtaining-the-gentoo-template)
*   [Updating / rebuilding the template](#updating--rebuilding-the-template)
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

## Updating / rebuilding the template

There are two kinds of "update", with different mechanics.

### A. Upgrade the software inside an already-installed template (routine)

A Gentoo template is a normal Qubes template: its root filesystem is
**persistent** (unlike an AppVM). So just upgrade in place — no rebuild:

```sh
# In dom0 (or over the remote-debug tunnel via qvm-run):
qvm-run -u root -- gentoo-xfce emerge --sync
qvm-run -u root -- gentoo-xfce emerge -uDN @world   # needs network / binhost
qvm-shutdown gentoo-xfce
```

Gentoo compiles from source, so a binhost makes this tractable — the build
already points portage at the TUNA binhost. This is the right path for security
updates and package bumps.

### B. Rebuild the template from the build recipe (changed packages/profile/overlay)

When you change the *build* — the flavor package list, the Portage profile, the
Qubes overlay, `make.conf`, etc. — you must rebuild the .rpm. This is the path
taken when e.g. adding a missing desktop component. The three repos involved:

- `qubes-builder-gentoo` (build scripts: `packages_*.list`, `distribution.sh`, …)
- `qubes-gentoo` (the Qubes guest-integration ebuild **overlay** → `/var/db/repos/qubes` in the chroot)
- `qubes-gentoo-template` (assembly + `config/build.conf`, the single source of truth for mirrors/profile/overlay/keys)

**Remote rebuild over the mgmt/remote-debug tunnel** (build qube = `gentoo-builder`
on the high-spec host; no GitHub, so sources are pre-placed as local tarballs):

```sh
# 1. Edit qubes-builder-gentoo, commit, and make a SIGNED tag (component verify
#    requires it): git -C qubes-builder-gentoo tag -s vX.Y.Z
# 2. Package WITHOUT .git (COPYFILE_DISABLE=1 to avoid macOS ._* null-byte trap),
#    scp to the jump's /tmp, then push into the build qube:
#      echo 'push-file mgmt-jump gentoo-builder <name>' | qrexec-client-vm dom0 qubes.RemoteDebug
#    Extract over artifacts/sources/builder-gentoo (keep its working copy; only
#    overwrite the changed files).
# 3. CLEAR THE STAMP or the build is a no-op ("prep already done ... Skipping"):
#    rm artifacts/templates/gentoo-xfce.{prep,build}.yml + the gentoo-xfce dirs +
#    old rpm; podman stop -a first (leftover overlays pile up). Then relaunch:
#      ./qb --builder-conf example-configs/gentoo-r4.3-slchris.yml -t gentoo-xfce template build
# 4. Install into dom0 (install-template auto-removes the old same-named template
#    first, so this is one step):
#      echo 'install-template gentoo-builder qubes-template-gentoo-xfce-4.3.0-<ts>.noarch.rpm' \
#        | qrexec-client-vm dom0 qubes.RemoteDebug
```

Handy read-only checks over the tunnel:
`pool-status` (dom0 thin-pool headroom — a root.img is ~19G, but the pool is
usually huge), `template-users <name>` (what references a template),
`untrust-template <name>` (manually remove a template installed by
install-template, if you're not reinstalling over it). See the
[remote-debug](../mgmt/remote-debug/) formula for these actions.

> **Package-atom gotcha:** every entry in `packages_*.list` is a full
> `category/name` atom. Verify the category against
> [packages.gentoo.org](https://packages.gentoo.org) before adding one — a wrong
> category (e.g. `x11-wm/xfwm4` instead of `xfce-base/xfwm4`) is silent until the
> single flavor-emerge, which aborts the whole prep after everything else built.

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
