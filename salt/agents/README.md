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
sys-bwg-net           project-net gateway; build exit, not the project exit
  ├─ agent-build      downloads the pinned bundle (its netvm)
  └─ UpdatesProxy     apt for tpl-agent-build, tpl-agents and tpl-gpg
        │  sha256-verified stream over qrexec
        ▼
tpl-agents              netvm=none; /opt/agents-bundle + /usr/local/bin wrappers
  └─ proj-<name>        netvm=sys-<project>-exit; credentials live here
```

## Files

| Path | Purpose |
|------|---------|
| `lock.yml` | pinned Node, agent and GUI application versions, URLs and digests |
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
- GUI applications: exact `.deb` URL + sha256 in `gui_apps`, installed with
  `dpkg`; `apt-get -f install` resolves their library dependencies in the
  template.
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
curl -fsSL https://downloads.claude.ai/claude-desktop/apt/stable/dists/stable/main/binary-amd64/Packages
curl -fsSL https://dl.google.com/linux/chrome/deb/dists/stable/main/binary-amd64/Packages
curl -fsSL https://packages.microsoft.com/repos/code/dists/stable/main/binary-amd64/Packages
```

Then edit `lock.yml` and run the update sequence below.

## GUI applications

`gui_apps` in `lock.yml` pins the official Linux beta Claude Desktop, Google
Chrome and VS Code. They ride in the same verified bundle as the CLI `.debs`;
`install-agents.sh` runs `dpkg -i` and then `apt-get -f install` to pull their
library dependencies from the template's normal apt mirror. No GUI app is
downloaded by the template itself.

`agents.template.create` reads each entry's `desktop_file` and adds it to the
template's Qubes app-menu whitelist, so new AppVMs see Chrome, VS Code and
Claude Desktop automatically. After a bundle is delivered:

- restart the AppVM so it boots from the updated template root;
- run `qvm-sync-appmenus <vm>` if the menu has not refreshed;
- AppVMs with a custom `menu-items` feature need the new desktop names added
  explicitly.

The bundle now carries roughly 400 MB of GUI `.deb` files in addition to the
agent artifacts; `agent-build:private` is already 20G, and the template root
volume must have room for the installed applications (~1–2 GB).

### Chrome, OAuth and the default browser

Chrome, VS Code and Claude Desktop are in `tpl-agents`. Two Qubes-specific
details make OAuth/browser login fail even when Chrome is installed:

1. **AppVMs created before the bundle have an old root snapshot.** They see
   `claude` but not Chrome/VS Code until they are restarted from the updated
   template. Stop and start the AppVM (not just the app); `agents.template.
   verify` checks the template, not the AppVM.
2. **Qubes points `xdg-open` at `qvm-open-in-dvm.desktop` in the user's
   `mimeapps.list`.** That overrides the template's Chrome default, so
   `xdg-open`/OAuth opens a DispVM. Apply `agents.configure` to the AppVM to
   set Chrome as the default for `http`, `https` and `text/html`.

```sh
sudo qubesctl --skip-dom0 --targets=proj-foo state.apply agents.configure
```

The app menu has a second Qubes quirk: a TemplateBasedVM keeps its own
`menu-items` feature from creation, so an older AppVM shows only Terminal/Start
even after it is restarted from the new template. Add the AppVM name to
`cfg.agents.qubes` and run `sudo qubesctl state.apply agents.prefs` (dom0);
new AppVMs inherit the template's default menu and do not need it.

### Timezone and locale follow the VPN exit

Qubes copies dom0's timezone into each AppVM at boot (`/qubes-timezone`).
That is what a running agent qube was using (`America/Atka`). The zone that
matches the session is the NetVM's WireGuard exit, stored in
`cfg.agents.exits`. `agents.exit` reads the qube's live netvm and writes
`vm-config.timezone` and `vm-config.locale`. It also sets `anon-timezone`,
so dom0's zone is not pushed into the qube. `qubes-agents-exit.service` in
`tpl-agents` applies the two features after `qubes-early-vm-config`.

Both live gateways exit in Los Angeles:

```jinja
"exits": {
  "sys-bwg-mullvad": {"timezone": "America/Los_Angeles", "locale": "en_US.UTF-8"},
  "sys-bwg-net": {"timezone": "America/Los_Angeles", "locale": "en_US.UTF-8"},
},
```

`tpl-agents` itself stays on UTC and generates every locale named in
`exits`. When a gateway's exit city changes, edit that entry and re-apply.
A netvm with no entry fails the state.

```sh
sudo qubesctl state.apply agents.exit
qvm-shutdown --wait proj-foo && qvm-start proj-foo
```

`agents.configure` runs the same script once, for a qube that is already up.

### Locale

These qubes log into Claude. Their locale and timezone follow the US
WireGuard exit (`en_US.UTF-8`, `America/Los_Angeles` on the current
gateways). This stack does not define a `zh_CN` locale or a China exit.
`tpl-agents` does not install `fcitx5`, and it does not install CJK fonts
(`fonts-noto-cjk`, `fonts-noto-cjk-extra`, WenQuanYi, AR PL).
`fonts-liberation` stays. Pages that need the removed faces will not
render those glyphs.

### WebRTC and audio

Chrome's WebRTC stack is bundled, but a minimal template has no audio daemon.
`tpl-agents` now installs `pulseaudio-qubes` (+ `pulseaudio-utils`,
`pavucontrol`). The **AppVM's** `audiovm` pref must also be set; the older
project-qube example set it to `""` (no sound). Use the default dom0 audio VM,
or `sys-audio` if you have one:

```sh
qvm-prefs proj-foo audiovm dom0
```

For camera/video, attach the webcam from `sys-usb` to the agent qube (for
example `qvm-usb attach proj-foo sys-usb:...`). Screen sharing via
`getDisplayMedia` is limited by Qubes' GUI isolation; treat it as unsupported
unless tested on your setup. The `agents.configure` state cannot set Qubes
prefs from inside the AppVM, so `audiovm` is a dom0 step.

If a foreign download is slow, stage the exact artifact on the LAN artifact
store (`10.31.0.2`) and point the lock's `url` at that path. The `sha256`
stays the same, so the build still verifies the pinned bytes; only the
transport changes. This is especially useful for the ~113 MB Claude Code
`.deb`, which has no China mirror.

### WebRTC IP handling

`tpl-agents` installs a Chrome managed policy at
`/etc/opt/chrome/policies/managed/webrtc.json`. It sets `WebRtcIPHandling`
to `disable_non_proxied_udp`. On this qube Chrome then gathers no ICE
candidates, so a STUN lookup cannot publish the VPN exit address. A page
that treats any numeric ICE address as a leak stays quiet. Browser video
calls that need a direct UDP path will not connect. Chrome reads the
policy at startup, so reopen it after the AppVM restarts onto the new
template root.

## Install order

The build qube's netvm is `cfg.agents.build.netvm` (`sys-bwg-net`). That
gateway is also the updates proxy for `tpl-agent-build` and `tpl-agents`.
Templates themselves stay without a netvm. Changing the build
netvm requires `agent-build` to be stopped. The gateway's WireGuard tunnel
has to be up first: project-net is fail-closed, and a down tunnel drops
both the bundle download and those templates' apt.

`agents.build.create` also grows `agent-build:private` to 20G
(`cfg.agents.build.private_size`). The default 2G is not enough for the Node
tarball, npm cache, four agent trees and the 113 MB Claude Code `.deb`; the
first build hit ENOSPC at 2G.

The `.top` files hardcode `tpl-agent-build`, `agent-build` and `tpl-agents`. If
you rename them in `config.jinja`, update the matching `.top` targets (or use
`qubesctl --targets=` directly).

```sh
# 0. Updates proxy on the build gateway. tinyproxy is installed into
#    tpl-project-net; restart the gateway so the running qube sees it.
sudo qubesctl --skip-dom0 --targets=tpl-project-net \
  state.apply templates.project-net.install
qvm-shutdown --wait sys-bwg-net && qvm-start sys-bwg-net
sudo qubesctl state.apply agents.updates-proxy

# 1. Build template + qube
sudo qubesctl state.apply agents.build.create

# 2. Toolchain in tpl-agent-build (apt leaves through sys-bwg-net)
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
qvm-prefs proj-foo netvm sys-foo-net   # the project's exit; must be in cfg.agents.exits
qvm-prefs proj-foo memory 800
qvm-prefs proj-foo maxmem 8000
qvm-prefs proj-foo audiovm dom0        # WebRTC audio; sys-audio if you have one
sudo qubesctl state.apply agents.exit  # zone + locale from that netvm, before first start
qvm-start proj-foo
sudo qubesctl --skip-dom0 --targets=proj-foo state.apply agents.configure
```

`agents.exit` binds the qube's timezone and locale to its netvm's VPN exit.
`agents.configure` applies that binding once and points the default browser
at Chrome (Qubes otherwise defaults `xdg-open` to `qvm-open-in-dvm`).

## Update

Two different things get updated, and both leave through `sys-bwg-net`.

**Pinned applications** — Chrome, Claude Desktop, Claude Code, the npm
agents, Helm 3, and sops. Versions live only in `lock.yml`. GitHub Actions
checks them once a day and opens a pull request. Merging that pull request
does not download or install anything. To apply a merged lock:

```sh
sudo qubesctl --skip-dom0 --targets=agent-build \
  state.apply agents.build.configure      # refresh lock.json/scripts
sudo qubesctl state.apply agents.build.run    # download via agent-build's netvm
sudo qubesctl state.apply agents.deliver
sudo qubesctl --skip-dom0 --targets=tpl-agents \
  state.apply agents.template.tools,agents.template.verify
qvm-shutdown --wait tpl-agents
# each AppVM keeps its old root until it is restarted
qvm-shutdown --wait mvtest
```

`agents.build.run` downloads in `agent-build`. That qube's netvm is the VPN
gateway, so the `.deb` and npm tarballs do not go out `sys-firewall`.
`agents.deliver` is idempotent: it compares the bundle sha256 already recorded
in `tpl-agents` and exits if it matches.

**Debian packages** inside `tpl-agent-build` and `tpl-agents` (library
dependencies and the toolchain). `tpl-agents` does not install `fcitx5` or
CJK fonts, and it writes the Chrome WebRTC policy described above.
`tpl-agents` also installs `xfce4-terminal` and selects it as
`x-terminal-emulator`, which is what `qubes-run-terminal` launches.
Re-apply the install state. Apt uses the updates proxy, which
`agents.updates-proxy` sends to the same gateway. The old `tpl-ai` and
`tpl-mcp` templates are not part of this stack; remove any leftover qubes
with `templates.retire-ai-mcp`.

```sh
sudo qubesctl --skip-dom0 --targets=tpl-agents \
  state.apply agents.template.install
sudo qubesctl --skip-dom0 --targets=tpl-agent-build \
  state.apply agents.build.install
qvm-shutdown --wait tpl-agents tpl-agent-build
```

Login stays on an AppVM built from `tpl-agents` (`mvtest`,
`slchris-project`), where Chrome is already the default browser.

Do not update these programs from inside an AppVM. The template owns the
binaries; an AppVM copy goes away on the next restart, or shadows the
template one. See the next section.

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
  Those credentials, and any private dotfiles, belong to one profile
  (`cfg.profiles`): that profile's project AppVM, its NetVM, its gpg qube,
  and its pass qube. `secrets.apply` runs on the project AppVM only. See
  [salt/secrets](../secrets/README.md). `agents.template.tools` installs
  Debian `age` and the sops pin from `lock.yml`.
- The bundle is installed system-wide in the template, so every AppVM based
  on it gets the same agent versions. If a project needs a different version,
  use a separate template (or a per-AppVM wrapper) rather than editing the
  shared tree.
- Split GPG 2 and Split SSH follow `cfg.profiles`. The project AppVM and
  the pass qube talk only to that profile's gpg qube. Policy is
  `templates.gpg.policy`. Packages are `templates.gpg.split` and
  `agents.template.split`. The client files are `agents.split`, and
  `dotfiles.git` writes the profile's signing key. Secret keys stay in
  the gpg qube.
- `agents.template.tools` adds `gh`, `kubectl`, `kustomize`, the Helm 3
  pin, Debian `age`, and the sops pin. Helm is held so the upstream
  repo's Helm 4 is not pulled in. sops is the upstream binary, not a
  Debian package named `sops`. It does not upgrade the rest of the
  template. Node stays in the bundle. Docker and the rest of a
  workstation toolchain are not installed.

## License

SPDX-License-Identifier: MIT

Copyright 2026 Chris Su
