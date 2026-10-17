# agents

Agent build pipeline for Qubes OS: one pinned bundle, one shared template,
many project AppVMs.

## Why

Qubes templates have no netvm; they only reach the network through the Qubes
update proxy, which is designed for apt/dnf. The coding agents (Claude Code,
Codex, opencode, pi, Grok Build, ...) are installed with npm or direct
downloads, so installing them in a template is unreliable — and installing them
per AppVM gives N copies, N update paths and version drift.

This unit builds all agents once in a dedicated AppVM (`agent-build`) that has
a real netvm, produces a content-addressed bundle, and installs that bundle
into a single template (`tpl-agents`). Project AppVMs are created from that
template and only hold their own credentials and code.

```
sys-<build-exit>  (Mullvad WireGuard / AnyTLS, later)
  └─ agent-build        downloads + builds the pinned bundle
        │  sha256-verified stream over qrexec
        ▼
tpl-agents              netvm=none; /opt/agents-bundle + /usr/local/bin wrappers
  └─ proj-<name>        netvm=sys-<project>-exit; credentials live here
```

## Files

| Path | Purpose |
|------|---------|
| `lock.yml` | pinned Node and agent versions, URLs and digests |
| `build/` | create/install/configure the build template and qube; run the build |
| `template/` | create/install/verify `tpl-agents` |
| `deliver.sls` | pull the newest bundle from `agent-build` into `tpl-agents` |
| `files/build-agents.sh` | runs in `agent-build`, produces the bundle |
| `files/install-agents.sh` | runs as root in `tpl-agents`, installs the bundle |
| `files/deliver-agents-bundle.sh` | dom0 relay, verifies and installs |

## Version policy

`lock.yml` is the single source of truth. The build resolves nothing except
what the lock says:

- Node: exact version + tarball URL + sha256.
- Claude Code: exact `.deb` URL + sha256, installed with `dpkg`.
- npm agents: exact package version, installed into a versioned prefix inside
  the bundle.

The bundle is a tarball with a sha256 recorded in `latest.sha256`. Old bundles
stay in `cfg.agents.build.bundle_dir`; old npm agent versions stay under
`/opt/agents-bundle/agents/<name>/<version>` and old `.deb` files stay in the
old bundle. That is the rollback path.

Resolve current versions with:

```sh
npm view @openai/codex version
npm view @opencode/cli version
npm view @earendil-works/pi-coding-agent version
npm view @xai-official/grok version
curl -fsSL https://nodejs.org/dist/latest-v22.x/SHASUMS256.txt
curl -fsSL https://downloads.claude.ai/claude-code/apt/stable/dists/stable/main/binary-amd64/Packages
```

Then edit `lock.yml` and run the update sequence below.

If a foreign download is slow, stage the exact artifact on the LAN artifact
store (`10.31.0.2`) and point the lock's `url` at that path. The `sha256`
stays the same, so the build still verifies the pinned bytes; only the
transport changes. This is especially useful for the ~113 MB Claude Code
`.deb`, which has no China mirror.

## Install order

The build qube has a netvm (`cfg.agents.build.netvm`, default `sys-firewall`).
Set it to a dedicated build exit when one exists; changing netvm requires the
qube to be stopped.

`agents.build.create` also grows `agent-build:private` to 20G
(`cfg.agents.build.private_size`). The default 2G is not enough for the Node
tarball, npm cache, four agent trees and the 113 MB Claude Code `.deb`; the
first build hit ENOSPC at 2G.

The `.top` files hardcode `tpl-agent-build`, `agent-build` and `tpl-agents`. If
you rename them in `config.jinja`, update the matching `.top` targets (or use
`qubesctl --targets=` directly).

```sh
# 1. Build template + qube
sudo qubesctl state.apply agents.build.create

# 2. Toolchain in tpl-agent-build
sudo qubesctl --skip-dom0 --targets=tpl-agent-build \
  state.apply agents.build.install

# 3. Lock + scripts in agent-build
sudo qubesctl --skip-dom0 --targets=agent-build \
  state.apply agents.build.configure

# 4. Shared agent template
sudo qubesctl state.apply agents.template.create
sudo qubesctl --skip-dom0 --targets=tpl-agents \
  state.apply agents.template.install

# 5. Download and build the pinned bundle (agent-build has the netvm)
sudo qubesctl state.apply agents.build.run

# 6. Deliver and install it into tpl-agents
sudo qubesctl state.apply agents.deliver

# 7. Verify every agent launcher
sudo qubesctl --skip-dom0 --targets=tpl-agents \
  state.apply agents.template.verify

# 8. Commit the template before creating/starting AppVMs
qvm-shutdown --wait tpl-agents
```

Create a project qube:

```sh
qvm-create --template tpl-agents --label blue proj-foo
qvm-prefs proj-foo netvm sys-foo-net   # the project's exit
qvm-prefs proj-foo memory 800
qvm-prefs proj-foo maxmem 8000
qvm-prefs proj-foo audiovm ""
qvm-start proj-foo
```

## Update

```sh
# edit lock.yml, then:
sudo qubesctl --skip-dom0 --targets=agent-build \
  state.apply agents.build.configure      # refresh lock.json/scripts
sudo qubesctl state.apply agents.build.run
sudo qubesctl state.apply agents.deliver
sudo qubesctl --skip-dom0 --targets=tpl-agents \
  state.apply agents.template.verify
qvm-shutdown --wait tpl-agents            # AppVMs pick it up on next start
```

`agents.deliver` is idempotent: it compares the bundle sha256 already recorded
in `tpl-agents` and exits if it matches.

## Self-update is disabled

The template owns the binaries:

- Claude Code: `/etc/claude-code/managed-settings.json` sets
  `DISABLE_UPDATES=1`, which blocks background updates and `claude update` /
  `claude install`.
- opencode: `OPENCODE_DISABLE_AUTOUPDATE=true` is set in
  `/etc/profile.d/agents.sh` and `/etc/environment.d/90-agents.conf`.
- Codex, pi and Grok Build update only when you run their update command;
  do not run it in an AppVM. Bump the lock instead.

If an AppVM already has a native Claude Code install in `~/.local/bin/claude`,
it shadows `/usr/bin/claude` because the repo's PATH setup prepends
`~/.local/bin`. Remove it once (`rm -f ~/.local/bin/claude` and
`rm -rf ~/.local/share/claude`); `~/.claude` credentials are unaffected.

## Boundaries

- `agent-build` has no credentials and no project data. npm install runs
  package lifecycle scripts; treat it as the untrusted-build boundary. Point
  its netvm at a dedicated build exit, not a project exit.
- `tpl-agents` has no netvm and no credentials. Project AppVMs have their own
  netvm and their own `~/.claude`, `~/.codex`, `~/.config/opencode`, etc.
- The bundle is installed system-wide in the template, so every AppVM based
  on it gets the same agent versions. If a project needs a different version,
  use a separate template (or a per-AppVM wrapper) rather than editing the
  shared tree.
- split-GPG / split-SSH are not part of this unit; see the repository's gpg
  and vault units and the discussion in the README.

## License

SPDX-License-Identifier: MIT

Copyright 2026 Chris Su
