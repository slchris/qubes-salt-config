# Deployment Checklist

An ordered, check-off-as-you-go guide to deploying qubes-salt-config from a
fresh machine to a fully working setup (templates + management + remote debug).

Each step notes **where** it runs — your **dev machine** (Mac), a **transfer
qube** (any networked AppVM), or **dom0**. Steps that can be driven remotely
once remote-debug is up are marked **[remote-ok]**.

> **Why a local deploy is required first.** `saltutil.sync_all` does NOT copy
> files, and the remote-debug qrexec whitelist only runs single `qubesctl`/`qvm-*`
> commands — it cannot run `setup.sh`. So the very first deploy of new code must
> be done locally (steps 1–3). After that, applying states can be remote.

## Table of Contents

*   [0. Prerequisites](#0-prerequisites)
*   [1. Configure](#1-configure)
*   [2. Package on the dev machine](#2-package-on-the-dev-machine)
*   [3. Deploy to the machine](#3-deploy-to-the-machine)
*   [4. Base templates](#4-base-templates)
*   [5. Management environment](#5-management-environment)
*   [6. Optional: download mirror](#6-optional-download-mirror)
*   [7. Remote debug (SSH from your dev machine)](#7-remote-debug-ssh-from-your-dev-machine)
*   [8. Application templates](#8-application-templates)
*   [9. Verify](#9-verify)
*   [Quick reference: the remote loop](#quick-reference-the-remote-loop)

## 0. Prerequisites

- [ ] Qubes OS **R4.3** (`sudo qubesctl --version` in dom0).
- [ ] Base minimal templates present (install if missing — **dom0**):
  ```sh
  qvm-check debian-13-minimal || sudo qubes-dom0-update --clean qubes-template-debian-13-minimal
  qvm-check fedora-43-minimal || sudo qubes-dom0-update --clean qubes-template-fedora-43-minimal
  ```
- [ ] A networked **transfer qube** for moving files (e.g. your `dev` qube).

## 1. Configure

- [ ] **[dev machine]** Edit `salt/config.jinja` — this project uses NO pillar;
      all settings live here:
  - template versions (`cfg.qvm.debian/fedora/whonix`)
  - mirror URLs + `enabled` (`cfg.mirror`)
  - remote-debug: `qube`, `ssh_port`, `lan_subnet`, `authorized_keys`
      (your dev machine's SSH public key), `dom0_access`

## 2. Package on the dev machine

- [ ] **[dev machine]** Build the tarball:
  ```sh
  cd ~/git/qubes-salt-config
  ./scripts/package.sh dev        # -> dist/qubes-salt-config-dev.tar.gz
  ```
- [ ] **[dev machine]** Serve it over the LAN:
  ```sh
  cd dist && python3 -m http.server 8000
  ```

## 3. Deploy to the machine

- [ ] **[transfer qube]** Pull and extract:
  ```sh
  cd ~ && rm -f qubes-salt-config-dev.tar.gz && rm -rf qubes-salt-config
  wget http://<dev-ip>:8000/qubes-salt-config-dev.tar.gz
  tar -xzf qubes-salt-config-dev.tar.gz
  ```
- [ ] **[dom0]** Copy into dom0 and run setup (this installs the minion config,
      copies `salt/` to `/srv/salt/slchris`, and removes any old broken pillar):
  ```sh
  cd ~
  qube="<transfer-qube>"
  rm -rf ~/QubesIncoming/"$qube"/qubes-salt-config
  mkdir -p ~/QubesIncoming/"$qube"
  qvm-run --no-gui --pass-io -- "$qube" "tar -cf - -C ~ qubes-salt-config" \
    | tar -xf - -C ~/QubesIncoming/"$qube"
  cd ~/QubesIncoming/"$qube"/qubes-salt-config
  sudo ./scripts/setup.sh
  ```
- [ ] **[dom0]** Sanity-check the config loaded (config.jinja, not pillar):
  ```sh
  ls /srv/salt/slchris/config.jinja
  ```

## 4. Base templates

The base minimal templates already exist (step 0). The formula's `create`
states make the base DisposableVM templates used downstream.

- [ ] **[dom0]** `sudo qubesctl state.apply debian-minimal.create`
- [ ] **[dom0]** `sudo qubesctl state.apply fedora-minimal.create`

## 5. Management environment

Required so `qubesctl --skip-dom0 --targets=<qube>` can run states inside DomU
qubes (it uses a management DisposableVM). Without this, every template
`install`/`configure` step fails.

- [ ] **[dom0]** `sudo qubesctl state.apply mgmt.create`
- [ ] **[dom0]** `sudo qubesctl --skip-dom0 --targets=tpl-mgmt state.apply mgmt.install`
- [ ] **[dom0]** `sudo qubesctl state.apply mgmt.prefs`   *(sets dvm-mgmt as management_dispvm)*
- [ ] **[dom0]** Verify: `qubes-prefs management_dispvm` shows `dvm-mgmt`.

## 6. Optional: download mirror

Helpful if ITL downloads are slow (e.g. in China). The shipped `config.jinja`
has `cfg.mirror.enabled: True` (Tsinghua TUNA) — set it to `False` to skip.
See [mirror.md](mirror.md).

- [ ] **[dom0]** `sudo qubesctl state.apply mgmt.mirror.dom0`
- [ ] **[dom0]** `sudo qubesctl --skip-dom0 --targets=debian-13-minimal state.apply mgmt.mirror.debian`
- [ ] **[dom0]** Verify: `grep -H '^baseurl' /etc/qubes/repo-templates/*.repo` shows the mirror.

## 7. Remote debug (SSH from your dev machine)

Lets you drive dom0 from your Mac afterward. See
[../salt/mgmt/remote-debug/README.md](../salt/mgmt/remote-debug/README.md) and
its Troubleshooting section. Order matters (create → template sshd → configure →
dom0 access → forward).

- [ ] **[dom0]** `sudo qubesctl state.apply mgmt.remote-debug.create`
- [ ] **[dom0]** `sudo qubesctl --skip-dom0 --targets=debian-13-minimal state.apply mgmt.remote-debug.install`
- [ ] **[dom0]** Restart the jump qube: `qvm-shutdown --wait mgmt-jump; qvm-start mgmt-jump`
- [ ] **[dom0]** `sudo qubesctl --skip-dom0 --targets=mgmt-jump state.apply mgmt.remote-debug.configure`
- [ ] **[dom0]** `sudo qubesctl state.apply mgmt.remote-debug.dom0-access`   *(installs the qubesctl whitelist!)*
- [ ] **[dom0]** `sudo qubesctl state.apply mgmt.remote-debug.netfw`
- [ ] **[dev machine]** Confirm SSH + dom0 channel:
  ```sh
  ssh -p 2333 user@<sys-net-physical-ip> "echo 'qvm-ls --raw-list' | qrexec-client-vm dom0 qubes.RemoteDebug"
  ```
- [ ] **[jump qube]** Add the helper to `~/.bashrc`:
  ```sh
  dom0() { printf '%s\n' "$*" | qrexec-client-vm dom0 qubes.RemoteDebug; }
  ```

> After step 7, the remaining steps can run **[remote-ok]** via `dom0 '...'`.

## 8. Application templates

Apply the ones you use. Each is `create` (dom0) → `install` (template) →
`configure` (the app/dvm qube). **[remote-ok]** once remote-debug works.

Debian-based: `dev`, `mcp`, `media`, `im`, `tools`, `gpg` (offline),
`vault` (offline). Fedora-based: `vpn`. Gentoo-based: `gentoo-dev`
(needs a Gentoo base template — you already have `gentoo-minimal`).

Example — `dev`:

- [ ] `sudo qubesctl state.apply templates.dev.create`
- [ ] `sudo qubesctl --skip-dom0 --targets=tpl-dev state.apply templates.dev.install`
- [ ] `sudo qubesctl --skip-dom0 --targets=dev,dvm-dev state.apply templates.dev.configure`

Repeat per template (swap `dev` → `mcp`/`gpg`/…). Offline templates (`gpg`,
`vault`) have no `configure` targets other than the app qube itself.

## 9. Verify

- [ ] Templates created: `qvm-ls | grep -E 'tpl-|dvm-'`
- [ ] A dev qube starts and has tools: `qvm-run dev 'code --version'` (for `dev`).
- [ ] Remote loop works end to end (see below).
- [ ] Restart the jump qube once and confirm SSH still works (persistence check).

## Quick reference: the remote loop

Once step 7 is done, from your **dev machine**:

```sh
# one-off
ssh -p 2333 user@<sys-net-ip> "echo '<qubesctl or qvm command>' | qrexec-client-vm dom0 qubes.RemoteDebug"

# interactive (after adding the dom0() helper on the jump qube)
ssh -p 2333 user@<sys-net-ip>
dom0 'qubesctl state.apply templates.mcp.create'
```

**Whitelist note:** the channel allows single commands only — **no shell pipes**
(`dom0 'qvm-ls | head'` returns empty). Pipe on your side instead.

**To deploy NEW code changes:** you must repeat steps 2–3 (package + setup.sh)
locally — remote cannot run setup.sh. Applying states with new code is remote
only after the files are on disk.
