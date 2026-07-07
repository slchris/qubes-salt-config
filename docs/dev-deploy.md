# Local Development Deploy

A fast, repeatable loop for pushing your local working copy of
`qubes-salt-config` onto a Qubes OS machine that lives on the **same LAN** — for
iterating during development, not for cutting a release.

The flow:

```
 dev machine                LAN                Qubes OS
┌────────────┐   HTTP    ┌───────────────┐  qvm-run  ┌──────┐
│ package.sh │ ────────> │ AppVM (e.g.   │ ────────> │ dom0 │ ──> setup.sh
│ + http srv │   wget    │ dev / dropbox)│  pass-io  │      │     sync_all
└────────────┘           └───────────────┘           └──────┘
```

> This is the **development** path. For the git-clone-in-a-qube install and the
> release tarball workflow, see [install.md](install.md).

## Table of Contents

*   [When to use this](#when-to-use-this)
*   [One-time setup](#one-time-setup)
*   [The loop](#the-loop)
    *   [1. Package on the dev machine](#1-package-on-the-dev-machine)
    *   [2. Serve it over the LAN](#2-serve-it-over-the-lan)
    *   [3. Pull into the transfer qube](#3-pull-into-the-transfer-qube)
    *   [4. Copy into dom0](#4-copy-into-dom0)
    *   [5. Deploy](#5-deploy)
*   [One-liners](#one-liners)
*   [Security notes](#security-notes)

## When to use this

Use it when you are editing the formulas on your laptop and want each change on
the Qubes box in seconds, without committing/pushing or building a signed
release. It trades the release workflow's integrity guarantees (checksums,
signed tags) for speed, so keep it to trusted LANs and development boxes.

## One-time setup

Pick a **transfer qube**: a normal networked AppVM (for example your `dev`
qube, or a dedicated `salt-dropbox` AppVM). **Do not use `sys-net`** — it is the
network attack surface and should not hold your source files. See
[Security notes](#security-notes).

Find the addresses you will reuse each loop:

```sh
# On the dev machine — its LAN IP (pick the 192.168.x/10.x address):
ip -4 addr | grep -w inet          # Linux
ipconfig getifaddr en0             # macOS

# In the transfer qube — confirm it can reach the dev machine:
ping -c1 <dev-ip>
```

Both machines must be on the same LAN and able to route to each other. Qube
networking goes out through `sys-firewall`/`sys-net`, so a qube can normally
reach a host on the physical LAN without extra config.

## The loop

### 1. Package on the dev machine

`scripts/package.sh` tars the working tree (excluding `.git`, `dist`, editor
cruft) into `dist/`:

```sh
cd ~/git/qubes-salt-config
./scripts/package.sh dev          # -> dist/qubes-salt-config-dev.tar.gz
```

Using a fixed label like `dev` (instead of the default date stamp) keeps the
filename stable so the later `wget`/deploy commands never change between
iterations.

### 2. Serve it over the LAN

Serve the `dist/` directory over a throwaway HTTP server:

```sh
cd dist
python3 -m http.server 8000
# Serving HTTP on 0.0.0.0 port 8000 ...
```

Leave this running in a terminal on the dev machine. Stop it with `Ctrl-C` when
you are done for the session.

### 3. Pull into the transfer qube

In a terminal **inside the transfer AppVM**:

```sh
cd ~
wget -N http://<dev-ip>:8000/qubes-salt-config-dev.tar.gz
tar -xzf qubes-salt-config-dev.tar.gz     # -> ~/qubes-salt-config/
```

`wget -N` only re-downloads if the file changed, which keeps repeat pulls quick.

### 4. Copy into dom0

> Read the Qubes warning on
> [copying to dom0](https://www.qubes-os.org/doc/how-to-copy-from-dom0/#copying-to-dom0)
> first. Only ever pull source you trust into dom0.

Qubes has no automatic file-copy *into* dom0, so stream it out of the qube with
`qvm-run --pass-io`. Run this **in dom0**:

```sh
qube="dev"        # <-- your transfer qube's name

# Replace any previous copy, then stream the extracted tree out of the qube.
rm -rf ~/QubesIncoming/"${qube}"/qubes-salt-config
mkdir -p ~/QubesIncoming/"${qube}"
qvm-run --no-gui --pass-io -- "${qube}" \
  "tar -cf - -C ~ qubes-salt-config" | \
  tar -xf - -C ~/QubesIncoming/"${qube}"
```

### 5. Deploy

Still **in dom0**, run the setup script and re-sync Salt so dom0 picks up your
changes:

```sh
cd ~/QubesIncoming/"${qube}"/qubes-salt-config
sudo ./scripts/setup.sh
```

`setup.sh` copies the files into `/srv/salt/slchris` and `/srv/pillar/slchris`,
installs the minion config, and runs `saltutil.sync_all` +
`saltutil.refresh_pillar` for you. After that, apply whatever state you are
working on — the per-template commands live in
[install.md](install.md#using-templates), for example:

```sh
sudo qubesctl state.apply templates.dev.create
sudo qubesctl --skip-dom0 --targets=tpl-dev state.apply templates.dev.install
```

If you only changed `.sls`/`.top`/pillar content and files are already in place,
you can skip `setup.sh` and just re-copy + re-sync:

```sh
sudo cp -r ~/QubesIncoming/"${qube}"/qubes-salt-config/salt/*   /srv/salt/slchris/
sudo cp -r ~/QubesIncoming/"${qube}"/qubes-salt-config/pillar/* /srv/pillar/slchris/
sudo qubesctl saltutil.sync_all
sudo qubesctl saltutil.refresh_pillar
```

## One-liners

Once set up, each iteration is three short steps.

**Dev machine** (after editing files):

```sh
./scripts/package.sh dev && ( cd dist && python3 -m http.server 8000 )
```

**Transfer qube**:

```sh
cd ~ && wget -N http://<dev-ip>:8000/qubes-salt-config-dev.tar.gz && \
  tar -xzf qubes-salt-config-dev.tar.gz
```

**dom0** (copy in + deploy):

```sh
qube="dev"; rm -rf ~/QubesIncoming/"$qube"/qubes-salt-config; \
  mkdir -p ~/QubesIncoming/"$qube"; \
  qvm-run --no-gui --pass-io -- "$qube" "tar -cf - -C ~ qubes-salt-config" | \
  tar -xf - -C ~/QubesIncoming/"$qube" && \
  cd ~/QubesIncoming/"$qube"/qubes-salt-config && sudo ./scripts/setup.sh
```

## Security notes

*   **Trusted LANs only.** Plain HTTP has no authentication or integrity check.
    Anyone on the LAN can read the archive or, if they win the race, serve a
    different one. Fine for a home/lab network; do not use it on untrusted or
    shared networks. For a release, use the checksummed tarball workflow in
    [install.md](install.md#packaging) instead.
*   **Don't stage source in `sys-net`.** Use a normal AppVM as the transfer
    qube. `sys-net` handles untrusted network hardware and traffic and is the
    most exposed qube; keeping build artifacts and an HTTP client's downloads
    out of it limits blast radius.
*   **dom0 is the crown jewels.** Everything you copy in runs with full
    privilege. Only ever pull a working copy you produced yourself, from a qube
    you control. Never point step 3 at a URL you don't own.
*   **Stop the server** (`Ctrl-C`) when finished so you are not leaving your
    source served on the LAN.
```
