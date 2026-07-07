# Remote Debug over SSH (Qubes)

A workflow for driving this Qubes machine from your dev laptop over SSH on the
LAN — so debugging `qubesctl`/Salt and the qubes doesn't mean typing everything
by hand at the physical console.

> **This is a development-only convenience with a real security cost. Read
> [Security & teardown](#security--teardown) before enabling it.** dom0 never
> runs sshd and never gets network — SSH terminates in a dedicated AppVM
> ("jump qube"), which reaches dom0 through qrexec.

> **There is now a Salt formula that does all of this for you** — deploy with
> `sudo qubesctl state.apply mgmt.remote-debug.*` and configure it via the
> `remote_debug` block in `pillar/user.sls`. See
> [salt/mgmt/remote-debug](../salt/mgmt/remote-debug/README.md). The manual
> steps below explain the same mechanism and are useful for understanding or
> one-off setups.

## Table of Contents

*   [Architecture](#architecture)
*   [1. Create the jump qube](#1-create-the-jump-qube)
*   [2. Enable SSH into the jump qube](#2-enable-ssh-into-the-jump-qube)
*   [3. Reach dom0 from the jump qube](#3-reach-dom0-from-the-jump-qube)
*   [4. Drive it from the Mac](#4-drive-it-from-the-mac)
*   [Security & teardown](#security--teardown)

## Architecture

```
  Mac (LAN)  ──ssh──▶  jump qube (AppVM, networked, sshd)
                            │
                            │  qrexec: qubes.VMShell + admin.* policy
                            ▼
                          dom0  ──▶  qubesctl / qvm-* / salt
```

- **dom0**: no sshd, no network. Only reachable via qrexec, gated by a policy
  file you install (and can remove).
- **jump qube**: a dedicated networked AppVM that accepts SSH from the Mac and
  relays commands into dom0.
- **Mac**: your `ssh` client. The same tunnel works whether *you* type
  interactively or an assistant wraps a command as `ssh jump "…"`.

## 1. Create the jump qube

In **dom0**, create a dedicated AppVM (do not reuse a dev/build qube — keep the
SSH entry point isolated):

```sh
# Debian-based, networked. Adjust template to one you have installed.
qvm-create --template debian-13-minimal --label red mgmt-jump
qvm-prefs mgmt-jump netvm sys-firewall
```

`mgmt-jump` being networked + SSH-exposed is exactly why it must be dedicated
and disposable-in-spirit: treat it as untrusted.

## 2. Enable SSH into the jump qube

SSH must survive reboots, so install/enable it in the **template**, and put the
authorized key + persistent config in the AppVM's `/rw`.

**In the template** (`debian-13-minimal`) — install the server:

```sh
sudo apt-get update && sudo apt-get install -y openssh-server
sudo systemctl disable ssh          # don't auto-start template-wide; AppVM enables it
```

**In `mgmt-jump`** (the AppVM) — persist key + autostart via `/rw/config/rc.local`:

```sh
# Put your Mac's public key in place (persists across reboots because /home is /rw).
mkdir -p ~/.ssh && chmod 700 ~/.ssh
cat >> ~/.ssh/authorized_keys <<'EOF'
ssh-ed25519 AAAA...your-mac-key... mac
EOF
chmod 600 ~/.ssh/authorized_keys

# Start sshd on every boot of this AppVM.
sudo tee -a /rw/config/rc.local >/dev/null <<'EOF'
#!/bin/sh
systemctl start ssh
EOF
sudo chmod +x /rw/config/rc.local
sudo systemctl start ssh
```

Find the qube's LAN-reachable IP:

```sh
ip -4 addr show eth0 | awk '/inet /{print $2}'
```

Qube networking is NAT'd behind `sys-net`, so a qube is **not** directly
reachable from the LAN by default. Two options:

- **Port-forward** from `sys-net` → `sys-firewall` → `mgmt-jump` (Qubes doc:
  "firewall / port forwarding"). More setup, keeps NAT.
- **Mesh VPN** (Tailscale/WireGuard) inside `mgmt-jump` — often simpler; the Mac
  and the qube join the same overlay and you `ssh <mgmt-jump-tailscale-ip>`.

Pick whichever fits your LAN. From here on, `JUMP` = that address.

## 3. Reach dom0 from the jump qube

dom0 exposes nothing by default. To let **only** `mgmt-jump` run commands in
dom0, install a qrexec policy **in dom0**.

> You chose the permissive option (arbitrary dom0 commands via `qubes.VMShell`).
> This is powerful and risky — see [Security & teardown](#security--teardown).
> The safer alternative is a whitelist service; it is described there too.

Create `/etc/qubes/policy.d/30-mgmt-jump.policy` in **dom0**:

```
# SPDX-License-Identifier: MIT
# Allow ONLY mgmt-jump to run shell commands in dom0. Dev-only; remove when done.
qubes.VMShell         *  mgmt-jump  dom0  allow
```

Reload isn't needed (policy.d is read per-call). Test from `mgmt-jump`:

```sh
echo 'qvm-ls --raw-list | head' | qrexec-client-vm dom0 qubes.VMShell
```

Wrap it so "run X in dom0" is one command — add this helper to your shell on
`mgmt-jump` (`~/.bashrc`):

```sh
# Run a command string in dom0 from the jump qube.
dom0() { printf '%s\n' "$*" | qrexec-client-vm dom0 qubes.VMShell; }
```

Now `dom0 'qubesctl state.apply debian-minimal.create'` works.

## 4. Drive it from the Mac

Add a host entry on the **Mac** (`~/.ssh/config`) so both you and any tooling
use a stable name:

```
Host qubes-jump
    HostName <JUMP-ip>
    User user
    IdentityFile ~/.ssh/id_ed25519
    ServerAliveInterval 30
```

Then, interactively:

```sh
ssh qubes-jump                       # land in mgmt-jump
dom0 'qubesctl state.apply templates.gentoo-dev.create'   # drive dom0
```

Or non-interactively (this is exactly how an assistant on the Mac can help —
it wraps each debug step as one line, reads the output back):

```sh
# Run something in the jump qube itself:
ssh qubes-jump 'emerge --info | head'

# Run something in dom0 through the jump qube:
ssh qubes-jump "dom0 'qubesctl saltutil.sync_all'"
ssh qubes-jump "dom0 'qubes-dom0-update --clean qubes-template-debian-13-minimal'"
```

Because it is plain non-interactive SSH, the round trip (command → output) is
scriptable, so iterative debugging (apply → read error → adjust → re-apply) no
longer needs the physical console.

## Security & teardown

**What you are accepting.** `qubes.VMShell … mgmt-jump dom0 allow` means: if
`mgmt-jump` is compromised (and it is networked + SSH-exposed, i.e. the most
attackable qube), **dom0 — and thus the whole system — is compromised.** This
discards Qubes' central isolation guarantee. It is acceptable only for a
disposable dev machine on a trusted LAN, used briefly, then torn down.

**Safer alternative (recommended for anything non-throwaway).** Instead of
`qubes.VMShell *`, install a whitelist qrexec service in dom0 that permits only
specific commands (e.g. `qubesctl state.apply <x>`, `saltutil.sync_all`). It is
~10 more minutes and does not hand dom0 to the AppVM. Ask and this repo can ship
that service + policy under `salt/mgmt`.

**Harden while it's up:**

- SSH: key-only auth (`PasswordAuthentication no`), and firewall `mgmt-jump` so
  only the Mac's IP can reach port 22 (`qvm-firewall`).
- Keep `mgmt-jump` off when not debugging (`qvm-shutdown mgmt-jump`); with sshd
  gated behind rc.local and a stopped qube, the entry point simply isn't there.

**Teardown (restore full isolation):**

```sh
# In dom0 — remove the dom0 access policy and the jump qube entirely:
sudo rm -f /etc/qubes/policy.d/30-mgmt-jump.policy
qvm-shutdown --wait mgmt-jump
qvm-remove mgmt-jump

# On the Mac — drop the host entry / key if desired.
```

Removing the policy file instantly revokes dom0 access even if the qube still
exists; removing the qube removes the SSH entry point.
