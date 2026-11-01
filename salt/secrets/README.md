# secrets

Private credentials for this public Salt tree.

This repository stays public. It stores no ciphertext and no secret values.
Tokens, kubeconfigs, `hosts.yml`, netrc files, WireGuard configs, and private
dotfiles live in a separate private git checkout. One profile is one
identity: its own project NetVM, agent AppVM, gpg qube, and pass qube.
Salt in this tree only knows that map and how to apply one profile's file
on that profile's project AppVM.

## What stays public

`salt/config.jinja` keeps non-secret identity and empty slots:

| Value | Where |
|-------|--------|
| Git name, email, signing subkey | `cfg.profiles.<name>.git` for a profile project; `cfg.qubes.<qube>.git` for any other AppVM |
| Tailscale auth key | `cfg.tailscale.auth_key`, left `""` |
| Hotspot password | `cfg.hotspot.password`, left `""` |
| Qubes Air API token, PVE token, encryption key, agent CA | `{data_dir}/secrets.env` on the console qube, mode `0600` |
| WireGuard `wg0.conf` | `/rw/config/wireguard/wg0.conf` inside the gateway, not Salt |

`dotfiles.git` writes `~/.gitconfig`. `dotfiles.shell` writes shell rc files
and, in the current config, sets `Asia/Shanghai`. Do not apply
`dotfiles.shell` to an agent qube. Private shell snippets are files in the
sops document, not more keys in `dotfiles.shell`.

## Private checkout

Clone the private repo inside the AppVM that will use it, not inside this
tree and not on dom0:

```
/home/user/src/qubes-salt-secrets/
  .sops.yaml
  secrets/profiles/slchris.yaml
```

`cfg.secrets.checkout` and `cfg.secrets.profile_file` are the public half of
that layout. `{profile}` is the key in `cfg.profiles`. The state runs only
when this AppVM is that profile's `project`. A pass qube keeps its password
store locally; this file is not copied there. An agent AppVM that is only
in `cfg.agents.qubes` (today, `mvtest`) is skipped.

The encrypted document is a `files` list. Each entry is a path, a mode, and
text content. `salt/secrets/files/qube.yaml.example` is the plaintext shape.
Copy `salt/secrets/files/.sops.yaml.example` to the private repo as
`.sops.yaml` before the first encrypt.

```sh
cd /home/user/src/qubes-salt-secrets
sops secrets/profiles/slchris.yaml
```

Modes the apply step accepts are `0600`, `0640`, `0700`, and `0750`.
Anything world-readable is refused. Paths must stay under `/home/user/` or
`/rw/`. `..`, a symlink, or a path outside those two roots fails the state.
The script logs paths, not contents, and wipes the decrypted temp file.

## Recipient

Each profile file is encrypted to that profile's encrypt subkey
(`cfg.profiles.<name>.pgp_fingerprint`), usage E. The slchris recipient is:

```
47A2A768885CC8501DD1BB4F108477BC92020DB1
```

The secret half stays on that profile's card. Another profile uses another
card and another gpg qube, and its file is encrypted to its own subkey.
Decrypt happens in the project AppVM: `sops` calls `gpg`, and that qube's
`gpg` is the split-gpg2 client pointed at `cfg.profiles.<name>.gpg`. The
card has to be attached for a cold decrypt. A warm PIN cache serves a later
run. dom0 does not get `sops`, an age private key, or the card.

`salt/templates/gpg/files/chris-su.asc` is a different key. It is not this
recipient.

An age recipient is optional, for the workstation while the card is in the
Qubes machine. Put the age **public** key in the private repo's `.sops.yaml`.
The age private key stays on that workstation (`SOPS_AGE_KEY_FILE` or the
sops default path) and never enters git. This formula does not generate one.

## Apply

```sh
sudo qubesctl --skip-dom0 --targets=slchris-project state.apply secrets.apply
```

| This AppVM | Checkout | This profile's yaml | Result |
|------------|----------|---------------------|--------|
| not a profile project | — | — | success, no changes |
| profile project | missing | — | success, no changes |
| profile project | present | missing | success, no changes |
| profile project | present | present, `sops` missing or decrypt fails | state fails |
| profile project | present | present, paths legal | files written as `user` |

The command waits up to 180 seconds so a PIN prompt can finish, then fails.
Re-run after the card is attached. A second run that finds the same bytes
and mode reports no changes.

`secrets.apply` is not a dom0 state. Enabling the top adds it to highstate
for each profile's project AppVM:

```sh
sudo qubesctl top.enable secrets.apply
```

## dom0 overlay

One secret is read on dom0: the hotspot password, because
`mgmt.hotspot` creates the NetworkManager connection from `cfg`. The
committed password is empty. Creation runs only when both `ifname` and
`password` are non-empty, and only when that connection does not already
exist, so an empty password leaves a live hotspot alone.

To rotate it, decrypt on the operator machine into `salt/config.local.jinja`
(start from `salt/config.local.jinja.example`). That file is gitignored.
`scripts/package.sh` excludes it and says so. Copy that one file to
`/srv/salt/slchris/config.local.jinja` on dom0, mode `0600`, then apply
`mgmt.hotspot`. Do not fold it into the public tarball.

`config.jinja` includes the overlay after the dict is built. The overlay
must update nested dicts in place. A broken overlay breaks every state,
because they all import `cfg`.

The password that used to be in `cfg.hotspot.password` is still in git
history. Rotating the Wi-Fi password is part of moving it.

## `sops` and `age` on the template

Debian trixie has an `age` package. It does not have Mozilla sops. The
packages named `sops`, `sos`, and `orca-sops` are different software; do
not install them.

`agents.template.tools` installs Debian `age` and the sops binary pinned
in `salt/agents/lock.yml` (`tools.sops`) at `/usr/bin/sops`. The digest
is checked before install. Apt and that download leave through `sys-bwg-net`.
A running AppVM sees them after `tpl-agents` is shut down and that AppVM
is restarted.

## License

SPDX-License-Identifier: MIT

Copyright 2026 Chris Su
