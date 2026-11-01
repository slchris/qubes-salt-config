# mgmt.gui-vnc — browser remote desktop for this Qubes machine

Drive **this** machine's desktop from a browser, so the physical monitor can be
used for something else. This is a different problem from `qubesair`/`remotevm`
(which manage a remote Proxmox fleet) and from `remote-debug` (which gives you a
shell in dom0).

Qubes composites every qube's windows in a **GUI domain**. The supported remote
variant is a **VNC GUI domain** — Qubes' own `qvm.sys-gui-vnc` — so this module
builds that, plus a browser client. The client is **KasmVNC**: its own Xvnc runs
on `:1` and mirrors the real display `:0` with `kasmxproxy`, so Qubes Manager,
the app menu and qube start/stop keep working exactly as they do locally.

```
browser ──https/ws──▶ sys-vncweb  (socat relay, networked)
                          │  qrexec: qubes.ConnectTCP+8444
                          ▼
                 sys-gui-vnc:8444   (GUI domain, no netvm, KasmVNC on localhost)
                          ▲
                          │ Xvnc :1 ◀── kasmxproxy ◀── :0 (lightdm)
                          │ guivm=<sys-gui-vnc> for tagged qubes
                    every AppVM's windows
```

There is no noVNC/websockify anymore. The front end copies the raw TLS/WebSocket
stream; TLS terminates at KasmVNC inside the GUI domain.

## What each state does

| State | Runs in | Purpose |
|-------|---------|---------|
| `clone` | dom0 | install the `*-xfce` GUI-domain template from `qubes-templates-itl` |
| `install` | that template | `qubes-vm-guivm` + XFCE + the lightdm Qubes drop-in; pinned KasmVNC RPM; tmpfiles fix so `qubes-update-gui` can write its log; hardens the retired x11vnc launcher; optionally installs the `qubes-vm-update` bridge wrapper |
| `create` | dom0 | create `sys-gui-vnc`, its base RPC policy and lightdm credential; enables the `kasmvnc` service and disables `guivm-vnc` |
| `global-settings` | dom0 | read-only Admin API grants (devices/properties/features/tags on every qube and dom0) for `qubes-global-config`; no write methods. The app still needs more dom0-only pieces — see below. Apply separately; `create` does not grant it |
| `updater-bridge` | dom0 | opt-in narrow `qubes.UpdateGui` qrexec service + policy so the GUI domain's Qubes Update app can call the dom0-only `qubes-vm-update`. Disabled by default |
| `kasm` | `sys-gui-vnc` | the persistent KasmVNC runtime: `/rw` config/scripts, certificate, credentials, Xvnc `:1`, `kasmxproxy`, adaptive-resize watcher, systemd units |
| `prefs` | dom0 | optionally set global `default_guivm` (opt-in, see below) |
| `web-create` | dom0 | clone the front-end template, create `sys-vncweb`, ConnectTCP+8444 policy |
| `web-install` | web template | `socat` + networking agent; removes `novnc`/`websockify` |
| `web-configure` | `sys-vncweb` | the socat TCP relay, persisted in `/rw` |
| `netfw` | dom0 | optional LAN DNAT to the front end (only if `web.network=portforward`) |
| `teardown` | dom0 | revert `default_guivm`, revoke policy, remove the qubes |

It is a port of Qubes' `qvm.sys-gui-vnc` / `qvm.sys-gui-template` /
`qvm.template-gui.jinja` to this repo's no-pillar, `config.jinja` style. The
RPC policy is copied from `gui_common()` because that is the part that is easy
to get subtly wrong.

## Configure

Everything is driven by `cfg.gui_vnc` in `salt/config.jinja` (see the long
comment there). The defaults build `sys-gui-vnc` on `fedora-43-xfce` and
`sys-vncweb` on a clone of `debian-13-minimal`, with a LAN port-forward on
`6080`.

Two keys deserve attention before you deploy:

- **`template`** must be an `*-xfce` template. The GUI-domain session is XFCE;
  a GNOME/minimal template will not give you a usable session. If
  `qubes-templates-itl` does not ship `fedora-43-xfce` on your version, point
  this (and `install.top` / `init.top`) at an XFCE template you do have.
- **`default_guivm`** is `True` on this machine: `mgmt.gui-vnc.prefs` points the
  whole machine at the GUI domain, so every qube's windows (and the app menu)
  are in the browser session. Setting it does **not** disturb running qubes —
  they move on their next start; a reboot moves everything. Do **not** run
  `qvm-shutdown --all` to force it (it stops `sys-usb`, killing a USB keyboard,
  and the network qubes, dropping SSH). To keep dom0 as the default and move
  only selected qubes, set it `False` and `qvm-prefs <qube> guivm sys-gui-vnc`.

## Deploy

Order matters across templates and qubes, and `qubesctl` cannot create a qube
and then configure it in one highstate, so apply the stages in sequence:

```sh
# 1. The XFCE GUI-domain template (downloads if absent)
sudo qubesctl state.apply mgmt.gui-vnc.clone

# 2. GUI-domain packages in that template, then STOP the template so the changes
#    (notably the lightdm wants-symlink) are committed before any AppVM is built
#    from it. An AppVM started while the template is still running snapshots the
#    on-disk template and misses the change — verified on R4.3.
sudo qubesctl --skip-dom0 --targets=fedora-43-xfce state.apply mgmt.gui-vnc.install
qvm-shutdown --wait fedora-43-xfce

# 3. The GUI domain, its RPC policy and its lightdm credential (starts it)
sudo qubesctl state.apply mgmt.gui-vnc.create

# 3.25 Qubes Global Settings needs read-only visibility of every qube's
#      devices, properties and features. This is separate from create because
#      it widens what the GUI domain can read; it grants no writes. The app
#      still needs dom0-only pieces and is not fully supported in a GUI
#      domain; see the verification notes below.
sudo qubesctl state.apply mgmt.gui-vnc.global-settings

# 3.3 (OPTIONAL) Make the Qubes Update GUI work in the GUI domain. Its backend,
#     qubes-vm-update, is a dom0-only package (QubesOS/qubes-issues#8934), so
#     the app otherwise dies with FileNotFoundError. Set
#     cfg.gui_vnc.updater_bridge = True first, then apply BOTH sides. Review
#     updater-bridge.sls: this lets the GUI domain trigger updates, including
#     dom0. The template wrapper needs the usual stop/restart to take effect.
sudo qubesctl state.apply mgmt.gui-vnc.updater-bridge
sudo qubesctl --skip-dom0 --targets=fedora-43-xfce state.apply mgmt.gui-vnc.install
qvm-shutdown --wait fedora-43-xfce
qvm-shutdown --wait sys-gui-vnc && qvm-start sys-gui-vnc

# 3.5 The KasmVNC runtime inside the GUI domain. On first run this generates a
#     self-signed certificate and a random KasmVNC password, stored in
#     /rw/config/kasmvnc/credentials.txt (read it from dom0 with qvm-run); an
#     existing pre-persistence KasmVNC password database is migrated as-is.
sudo qubesctl --skip-dom0 --targets=sys-gui-vnc state.apply mgmt.gui-vnc.kasm

# 4. The browser front end: template + qube + ConnectTCP policy. Same rule:
#    install into the template, STOP it, then start the AppVM.
sudo qubesctl state.apply mgmt.gui-vnc.web-create
sudo qubesctl --skip-dom0 --targets=tpl-gui-vnc-web state.apply mgmt.gui-vnc.web-install
qvm-shutdown --wait tpl-gui-vnc-web
qvm-start sys-vncweb
sudo qubesctl --skip-dom0 --targets=sys-vncweb state.apply mgmt.gui-vnc.web-configure

# 5. Expose it on the LAN (skip if web.network != "portforward")
sudo qubesctl state.apply mgmt.gui-vnc.netfw

# 6. Hand the desktop to the GUI domain. REQUIRES shutting down every qube
#    first; do this last, on purpose.
qvm-shutdown --all --wait
sudo qubesctl state.apply mgmt.gui-vnc.prefs   # only if default_guivm = True
```

## Access

This is a **LAN** feature — the same shape as `mgmt.remote-debug`, where the
port-forward lands on **sys-net's physical IP**. `sys-net` holds the physical
NIC, so that is the address your laptop dials; `qvm-prefs sys-net ip` gives its
*internal* address and is the wrong one.

```sh
# on dom0: the LAN-reachable address (find the one that is not 127.0.0.1)
qvm-run --pass-io sys-net 'ip -4 addr show | grep -v 127.0.0.1'
```

Then, from any machine on `cfg.remote_debug.lan_subnet`
(`10.31.0.0/24` and `10.42.0.0/24` by default):

```
https://<sys-net-physical-IP>:6080/
```

The certificate is self-signed (generated in the GUI domain), so the browser
shows a warning once. KasmVNC asks for its own username/password (default user
`kasmgui`; the password is in `/rw/config/kasmvnc/credentials.txt`, or in the
pre-persistence credentials note you used before). After that, lightdm inside
the GUI domain may ask for the `user` account's dom0 password (see
`sync_dom0_password` above); if the session is already logged in, lock it
before disconnecting. Nothing is exposed unless `web.network = "portforward"`
and `mgmt.gui-vnc.netfw` was applied.

For a 1:1, adaptive display, open the KasmVNC client's sidebar and set
**Scaling → Remote Resizing**. The client then asks Xvnc `:1` for a new size and
`qubes-kasm-resize.service` selects the same size as a CRTC mode on the real
`:0` display, so text renders at native resolution and Qubes can read the
geometry back. **Local Scaling** is the fallback (the server keeps its current
size and the browser scales it). Do not use `kasmxproxy -r`: it segfaults on
this Xorg and is not installed by this module. Do not resize `:0` with a bare
`xrandr --fb`: the dummy output keeps the framebuffer size but loses its mode,
`get_monitor_layout()` returns nothing, and the next `qubes.SetMonitorLayout`
turns the guest outputs off (a 64x64 screen, so the pointer never hits a
window).

> **Connection refused even though you are on the LAN?** Check whether your
> laptop is on the tailnet and accepting routes. `cfg.tailscale` advertises
> `10.31.0.0/24`, so a laptop that accepts that route sends traffic for sys-net's
> LAN IP *through Tailscale*; Tailscale SNATs it, the source no longer matches
> `lan_subnet`, and the DNAT ignores it. Turn off route acceptance on the laptop
> (or stop advertising `10.31.0.0/24`) if you rely on the LAN port-forward.

> **The page resets and sys-vncweb logs `Request refused`?** The dom0
> qrexec-policy journal may show `qubes.ConnectTCP+8444 ... allowed to
> sys-gui-vnc` while the target GUI domain's socket-service state is stale
> after a boot (observed once after a GUI-domain reboot). Restart the GUI
> domain (`qvm-shutdown sys-gui-vnc`, then `qvm-start sys-gui-vnc`) and retry.
> If it recurs, stop the GUI-domain template before restarting the GUI domain
> so the AppVM snapshot is consistent; see the template-commit note in the
> verification section. The read-only `qpolicy` action on the remote-debug
> channel prints the policy files and the qrexec-policy journal.

### Performance / latency

A LAN session can still feel laggy because the path is software-only, not
because the network is slow. Measured on this machine: route via the physical
NIC with ~8 ms RTT; the browser proxy excludes `10.0.0.0/8`; the first TLS
handshake through socat → qrexec takes 2–8 s, later connections ~35–55 ms, and
the HTTP/data RTT after the handshake is ~5 ms. The first-connection delay is
the per-connection `socat`/`qrexec.ConnectTCP` setup (KasmVNC's web client opens
many connections for its assets); the steady-state path is the LAN.

The steady-state cost is the display pipeline: Xorg `dummyqbs` on `:0` →
`kasmxproxy` → Xvnc `:1` → KasmVNC encoding. KasmVNC dlopens the system
`libavcodec` and, for codec `h264`, asks for the encoder named `libx264`.
Fedora's `ffmpeg-free` does not include it. `mgmt.gui-vnc.install` enables the
RPM Fusion free repo and swaps `ffmpeg-free` for RPM Fusion's `ffmpeg` (same
7.1 soname) so `libx264` is in that library. `kasmvnc.yaml` sets
`video_streaming_mode.codec` to `h264`.

`webp` is not a valid video codec here (the log says "Unknown codec webp
skipped") and only forces the WebP/JPEG image path, which is what made a LAN
session feel laggy. `auto` also tries H.265 and used to black the canvas when
that encoder was missing. The yaml still:

- caps `encoding.max_frame_rate` at 30,
- lowers `video_encoding_mode` WebP/JPEG quality to 5 and caps that fallback at
  1920x1080 (used when the client asks for the image path),
- the XFCE compositor is disabled (`xfwm4 /general/use_compositing=false`),
- `sys-vncweb`'s socat listener uses `nodelay`, and
- `sys-gui-vnc` is configured for 4 vCPUs (takes effect on its next start).

The encoder is in the template root, so a running GUI domain keeps the old
libraries until it is restarted. Further levers:

- In the KasmVNC client sidebar, set **Quality → Low/Medium**; the client can
  override the server's frame rate/quality.
- Resize the browser window (Remote Resizing) to a smaller display; 2560x1288
  is ~1.7x the pixels of 1920x1080. Text is sharper at native size, so this is
  a trade-off.
- A larger refactor is to make KasmVNC's Xvnc the primary `:0` X server and drop
  Xorg `dummyqbs` + `kasmxproxy`; that removes one full framebuffer copy but
  changes the Qubes GUI-domain display server setup.

## Usage

- **Login:** KasmVNC asks for its own username/password first (`kasmgui` plus
  the password in `/rw/config/kasmvnc/credentials.txt`, or the migrated one).
  After that, lightdm inside the GUI domain asks for the template `user`'s
  **dom0 password** (`sync_dom0_password`). If you set that to `False`, set the
  password yourself first:
  `qvm-run -u root sys-gui-vnc 'passwd user'`.
- **Only some qubes on the GUI domain**, leaving dom0 as the default and the
  physical screen working as before:
  `qvm-prefs <qube> guivm sys-gui-vnc` (and back with `... guivm dom0`).
- **`default_guivm` = the whole machine:** all qube windows go to VNC and the
  physical screen shows only dom0. Revert with
  `qubes-prefs default_guivm dom0` and `qvm-prefs <qube> guivm dom0` for any
  per-qube overrides.

### Turning the exposure off

Set `web.network` to anything other than `"portforward"` and re-apply `netfw`:
no DNAT is installed and `6080` is not reachable from the LAN. The units keep
running inside `sys-vncweb`; if you need to poke at them, do it from dom0 with
`qvm-run`.

## Verify

```sh
# The qube exists with the Qubes GUI-domain settings
qvm-prefs sys-gui-vnc netvm          # -> '' (empty)
qvm-prefs sys-gui-vnc guivm          # -> dom0
qvm-service sys-gui-vnc              # -> lightdm, guivm, kasmvnc: on; guivm-vnc off

# The RPC policy is present
cat /etc/qubes/policy.d/50-gui-sys-gui-vnc.policy
cat /etc/qubes/policy.d/50-gui-vnc-web.policy

# Inside the GUI domain: the three KasmVNC units and the loopback listener
qvm-run --pass-io -u root sys-gui-vnc 'systemctl status qubes-kasmvnc qubes-kasmxproxy qubes-kasm-resize --no-pager | grep -E "Active|Loaded"'
qvm-run --pass-io -u root sys-gui-vnc 'ss -lntp | grep 8444'

# The mirror is alive: both displays should report the same current size
qvm-run --pass-io -u root sys-gui-vnc 'XAUTHORITY=/root/.Xauthority-kasm xrandr --display :0 --current | head -1; XAUTHORITY=/root/.Xauthority-kasm xrandr --display :1 --current | head -1'

# Inside the front end: the TCP relay is up
qvm-run --pass-io -u root sys-vncweb 'systemctl status qubes-gui-vnc-web --no-pager | head -3; ss -lntp | grep 6080'

# From the LAN, KasmVNC answers (401 = Basic Auth is doing its job)
curl -k -I https://<sys-net-physical-IP>:6080/
```

## Security

This is the security cost of remote desktop, stated plainly:

- **Anyone who reaches the KasmVNC session and logs in controls the whole
  machine.** The Qubes GUI-domain docs say the same. KasmVNC is loopback-only,
  requires its own password, and is gated by the `qubes.ConnectTCP` policy; the
  web leg uses TLS with a self-signed certificate. The KasmVNC password is not
  the dom0 password. The real doors remain the browser front end (port `6080`),
  the KasmVNC password, and lightdm.
- **The desktop stays logged in after the viewer disconnects.** Lock it
  (`xflock4`/`dm-tool lock`) or log out before closing the browser, as the
  Qubes GUI-domain docs advise; otherwise the next viewer finds the unlocked
  session.
- **Off-LAN access needs a cryptographic wrapper.** The official docs call the
  bare VNC setup suitable for test machines only and recommend a VPN (or an
  equivalent authenticated tunnel) when the listener faces an open network.
  Keep the DNAT restricted to `remote_debug.lan_subnet`; use an SSH tunnel/VPN
  or replace/pin the self-signed KasmVNC certificate behind a trusted terminator
  before widening it.
- **`default_guivm` moves the machine's trust boundary into a networked-adjacent
  qube.** The GUI domain has no netvm, but it does run an X session and KasmVNC;
  keep it patched like a template. The separate `mgmt.gui-vnc.global-settings`
  state grants read-only device/property/feature visibility so Global Settings
  works; device reassignment is deliberately not granted.
- **The front end is a networked TCP relay.** `portforward` opens `6080` to
  every subnet in `cfg.remote_debug.lan_subnet`; narrow that list to your real
  LAN. KasmVNC terminates TLS inside the GUI domain, so the LAN leg is
  encrypted, but the certificate is self-signed and the front end adds no
  authentication of its own. Pin the certificate or put the relay behind a
  trusted TLS terminator/VPN before widening exposure; do not widen
  `lan_subnet`.
- **`sync_dom0_password` writes your dom0 shadow hash into `sys-gui-vnc`.** That
  qube has no network and only lightdm reads the file, but it is a credential
  leaving dom0. Set it `False` if you would rather set the guivm password by
  hand.
- `admin_global_permissions` defaults to `'rwx'` to match Qubes; `'ro'` or
  `'none'` narrows what the GUI domain can ask dom0 to do.

## Qubes practice

The official GUI-domain documentation and the community converge on the same
shape this module uses:

*   The VNC server listens on localhost inside the GUI domain; the GUI domain
    has no NetVM and is reached through `qubes.ConnectTCP` from a separate qube.
    This module runs KasmVNC on `localhost:8444`, still loopback-only.
    ([Qubes GUI-domain docs](https://doc.qubes-os.org/en/r4.3/user/advanced-topics/gui-domain.html))
*   The intended authentication is the display manager: log in as the earliest
    dom0 user in the `qubes` group with the dom0 password. The desktop stays
    logged in after the viewer disconnects, so lock or sign out first. (same
    docs)
*   The docs warn that anyone who can reach the VNC port can seize the whole
    machine, a second viewer can join and may kick the first off, and the bare
    setup is suitable only for test machines. If it faces an open network, put
    a cryptographic wrapper such as a VPN in front. (same docs)
*   Qusal's `sys-gui-vnc` keeps a default-deny inter-qube policy and allows
    only the trusted client qube to reach port 5900; exposure is expected to
    go over VPN/SSH.
    ([qusal sys-gui-vnc](https://git.hackliberty.org/Git-Mirrors/qusal/src/branch/main/salt/sys-gui-vnc))
*   Qubes issue [#6740](https://github.com/QubesOS/qubes-issues/issues/6740)
    tracks the GUI-domain password/persistence design; the lightdm password is
    not a strong remote-auth mechanism on its own.
*   Browser-based VNC should terminate TLS rather than expose plain HTTP.
    KasmVNC does this natively; this module keeps its listener loopback-only
    and lets sys-vncweb relay the ciphertext. The certificate is self-signed,
    which is adequate for a trusted LAN but must be pinned or replaced behind a
    trusted terminator before widening exposure.
    ([KasmVNC](https://github.com/kasmtech/KasmVNC))

This module follows that model (localhost KasmVNC, ConnectTCP, lightdm) and
adds a KasmVNC password as an extra gate in front of the already-logged-in GUI
session. It deliberately does **not** widen the network: the browser front end
is LAN-only, so use an SSH tunnel/VPN if that is not enough.

## Verification status

**KasmVNC path verified on real Qubes R4.3 hardware (2026-10-18), deployed
through the `mgmt-remote-debug` SSH channel, with `default_guivm =
sys-gui-vnc`:**

- KasmVNC 1.5.0 is installed from the pinned RPM in `fedora-43-xfce`. The GUI
  domain serves HTTPS/WebSocket on `127.0.0.1:8444`; the LAN relay on `6080`
  returns `401` (KasmVNC Basic Auth) end to end. On one GUI-domain boot the
  target-side ConnectTCP state was stale while the dom0 qrexec journal showed
  the call as allowed; restarting `sys-gui-vnc` restored the relay (see the
  troubleshooting note under Access).
- `mgmt.gui-vnc.kasm` persists the config, certificate, password database and
  helper scripts in `/rw/config/kasmvnc`. After a full GUI-domain
  poweroff/start, `lightdm`, `qubes-kasmvnc`, `qubes-kasmxproxy` and
  `qubes-kasm-resize` all came up active with no manual step. `:0` and `:1`
  were both 2048x1536 and their root-window screenshots were byte-identical.
- Adaptive resize: changing the `:1` size with RandR moved `:0` to the same
  size (verified 1470x802 -> 1600x900 -> 1470x802); the mirror stayed
  byte-identical and all units stayed active. The watcher restarts only
  `qubes-kasmxproxy`; the browser's KasmVNC connection lives on Xvnc `:1` and
  is not disconnected. The KasmVNC client's own **Remote Resizing** menu was
  not exercised by the automated test; the watcher's input was simulated with
  `xrandr`.
- Qubes Manager, the app menu, qube start/stop and the noVNC feature set work in
  the browser session. `novnc`/`websockify` are removed; sys-vncweb is a raw
  socat relay.
- `qubes-update-gui`'s `PermissionError: /var/log/qubes/qui.updater.log` is
  fixed by the template tmpfiles rule and by `apply-units.sh`, which runs from
  `/rw/config/rc.local` before lightdm. It is **not enough** to make the app
  work: the GUI domain has no `qubes-vm-update` CLI, because `qubes-vmupdate`
  is packaged for dom0 only (the VM repos have no such package;
  QubesOS/qubes-issues#8934). The stock app dies at
  `qui/updater/intro_page.py` with `FileNotFoundError: qubes-vm-update`. The
  opt-in `mgmt.gui-vnc.updater-bridge` is the workaround implemented here: it installs
  a narrow `qubes.UpdateGui` dom0 service and a `qubes-vm-update` wrapper in
  the template. It is **off by default** because it lets the GUI domain trigger
  updates, including dom0; enable it deliberately.
- **Global Settings is a dom0 app, not fully usable from the GUI domain.** The
  separate `mgmt.gui-vnc.global-settings` state is still useful: it fixes the
  first wave of `QubesDaemonAccessError: Request refused` failures
  (`admin.vm.device.pci.Attached`, property/feature/tag/volume reads) by
  granting read-only visibility on the concrete VM classes and dom0. Two
  policy details matter: the Admin API request is sent to dom0, so every
  non-dom0 line needs `target=dom0`; and `@anyvm` is not expanded as an Admin
  API target on R4.3, so the lines use
  `@type:AppVM/TemplateVM/DispVM/StandaloneVM`. Even with those grants, the app
  then calls the dom0 policy admin client (`policy.Get` on
  `50-config-*`, which is dom0-only) and `qubes-hcl-report`
  (`FileNotFoundError`), and the stock app can hit `admin.vm.List` vchan
  timeouts under KasmVNC's many per-connection qrexec channels. Use Qubes
  Manager for per-qube actions; run Global Settings in dom0 (or over the
  mgmt-jump channel). If you do not need even the read-only grants, revoke
  them with `mgmt.gui-vnc.global-settings` after setting
  `gui_vnc.enabled = False`, or delete
  `/etc/qubes/policy.d/51-gui-global-settings.policy` in dom0.

Bugs found and fixed while moving from x11vnc/noVNC to KasmVNC:

1. **`service.enabled` does not enable lightdm.** The unit carries
   `Alias=display-manager.service`, so `systemctl is-enabled` reports it enabled
   and Salt never creates `multi-user.target.wants/lightdm.service`. The 2026-09
   deploy fixed this with an explicit `systemctl enable lightdm` in
   `install.sls`. On the 2026-10 re-apply the qvm state also dropped the
   `lightdm` qube service; `create.sls` now runs `qvm-service -e <qube>
   lightdm` explicitly, and `apply-units.sh` touches the marker from rc.local.
2. **Retiring `guivm-vnc` also removes the lightdm Xorg setup.** The stock
   lightdm `ExecStartPre` calls `qubes-run-x11vnc pre`, which only renders
   `/etc/X11/xorg.conf` when the `guivm-vnc` service is on. With that service
   retired, Xorg found no screen (`no screens found`) and the browser showed
   black. `gen-xorg-conf.sh` now sources Qubes' `guivm_vnc_pre` function without
   starting x11vnc, and a lightdm drop-in runs it at every start; rc.local also
   renders the config before lightdm.
3. **`kasmxproxy -r` segfaults on this Xorg.** It crashed after a browser
   resize and left `:1` black. The module runs the proxy without `-r` and
   `qubes-kasm-resize.service` copies the `:1` size onto a real `:0` CRTC mode,
   then restarts the proxy when the size changed. The browser connection is to
   Xvnc `:1`, so it survives. The mode (not a bare `xrandr --fb`) is required:
   without it the guest RandR screen drops to 64x64 and the pointer misses.
4. **Template changes must be committed (template stopped) before an AppVM is
   started from it.** An AppVM started while the template is still running
   misses new files. The deploy sequence stops the template between `install`
   and `create`; the KasmVNC runtime itself lives in `/rw` and does not depend
   on that snapshot.

**Still unverified:** `teardown` (not exercised); the backends' behaviour on a
machine whose `sys-firewall` is not the standard double-NAT path; the KasmVNC
client's Remote Resizing UI; the optional updater bridge's full update run
(the service and wrapper are implemented, but the bridge is off by default and
was not exercised end to end); and device reassignment from Global Settings
(the read-only grants intentionally do not allow writes). Global Settings
itself is known to need dom0-only calls, so it is not expected to work in the
GUI domain. The `@tag:guivm-<qube>` policy lines were checked against Qubes
source — the tag is maintained by `qubes/ext/gui.py` — not merely assumed.

## Teardown

```sh
sudo qubesctl state.apply mgmt.gui-vnc.teardown
```

Reverts `default_guivm` to dom0, removes both policy files and the admin-include
blocks, then removes `sys-vncweb`, its template and `sys-gui-vnc`. Set
`cfg.gui_vnc.keep_qubes = True` to revoke access but keep the qubes.
