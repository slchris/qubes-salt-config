# mgmt.gui-vnc — browser remote desktop for this Qubes machine

Drive **this** machine's desktop from a browser, so the physical monitor can be
used for something else. This is a different problem from `qubesair`/`remotevm`
(which manage a remote Proxmox fleet) and from `remote-debug` (which gives you a
shell in dom0).

Qubes composites every qube's windows in a **GUI domain**. The supported remote
variant is a **VNC GUI domain** — Qubes' own `qvm.sys-gui-vnc` — so this module
builds that, plus a **noVNC** front end that puts it in a browser tab.

```
browser ──http/ws──▶ sys-vncweb  (noVNC + websockify, networked)
                          │  qrexec: qubes.ConnectTCP+5900
                          ▼
                     sys-gui-vnc:5900   (GUI domain, no netvm, VNC on localhost)
                          ▲
                          │ guivm=<sys-gui-vnc> for tagged qubes
                    every AppVM's windows
```

## What each state does

| State | Runs in | Purpose |
|-------|---------|---------|
| `clone` | dom0 | install the `*-xfce` GUI-domain template from `qubes-templates-itl` |
| `install` | that template | `qubes-vm-guivm` + XFCE + the lightdm Qubes drop-in |
| `create` | dom0 | create `sys-gui-vnc`, its RPC policy, and the lightdm credential |
| `prefs` | dom0 | optionally set global `default_guivm` (opt-in, see below) |
| `web-create` | dom0 | clone the front-end template, create `sys-vncweb`, ConnectTCP policy |
| `web-install` | web template | `novnc`, `websockify`, `socat`, networking agent |
| `web-configure` | `sys-vncweb` | the socat tunnel + websockify units, persisted in `/rw` |
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
http://<sys-net-physical-IP>:6080/vnc.html
```

The first screen is the GUI domain's lightdm. Log in as `user` with your dom0
password (see `sync_dom0_password` above). Nothing is exposed unless
`web.network = "portforward"` and `mgmt.gui-vnc.netfw` was applied.

> **Connection refused even though you are on the LAN?** Check whether your
> laptop is on the tailnet and accepting routes. `cfg.tailscale` advertises
> `10.31.0.0/24`, so a laptop that accepts that route sends traffic for sys-net's
> LAN IP *through Tailscale*; Tailscale SNATs it, the source no longer matches
> `lan_subnet`, and the DNAT ignores it. Turn off route acceptance on the laptop
> (or stop advertising `10.31.0.0/24`) if you rely on the LAN port-forward.

## Usage

- **Login:** lightdm inside the GUI domain, as the template's `user`, with your
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
qvm-service sys-gui-vnc              # -> lightdm, guivm, guivm-vnc: on

# The RPC policy is present
cat /etc/qubes/policy.d/50-gui-sys-gui-vnc.policy
cat /etc/qubes/policy.d/50-gui-vnc-web.policy

# Inside the GUI domain: VNC listening on loopback only, lightdm up
qvm-run --pass-io -u root sys-gui-vnc 'ss -lntp | grep 5900; systemctl status lightdm --no-pager | head -3'

# Inside the front end: both units are up and websockify is bound
qvm-run --pass-io -u root sys-vncweb 'systemctl status qubes-gui-vnc-bridge qubes-gui-vnc-web --no-pager | grep -E "Active|Listening"'

# From the front end, the qrexec tunnel resolves (policy in place)
qvm-run --pass-io -u root sys-vncweb 'timeout 3 socat - TCP:127.0.0.1:5901 </dev/null | head -c 12 | xxd'
# -> starts with "RFB " when the GUI domain is serving VNC
```

## Security

This is the security cost of remote desktop, stated plainly:

- **Anyone who reaches the VNC session and logs in controls the whole machine.**
  The Qubes GUI-domain docs say the same. The VNC server itself is loopback-only
  and gated by the `qubes.ConnectTCP` policy, so the real doors are the browser
  front end (port `6080`) and the lightdm password (your dom0 password).
- **`default_guivm` moves the machine's trust boundary into a networked-adjacent
  qube.** The GUI domain has no netvm, but it does run an X session and a VNC
  server; keep it patched like a template.
- **The front end is a networked web server.** `portforward` opens `6080` to
  every subnet in `cfg.remote_debug.lan_subnet`; narrow that list to your real
  LAN. websockify has **no TLS** here, so the lightdm password and the whole
  session cross the LAN in cleartext — this is intended for a trusted LAN. If
  you ever need off-LAN access, terminate TLS at the front end or put the bridge
  behind a VPN; do not widen `lan_subnet`.
- **`sync_dom0_password` writes your dom0 shadow hash into `sys-gui-vnc`.** That
  qube has no network and only lightdm reads the file, but it is a credential
  leaving dom0. Set it `False` if you would rather set the guivm password by
  hand.
- `admin_global_permissions` defaults to `'rwx'` to match Qubes; `'ro'` or
  `'none'` narrows what the GUI domain can ask dom0 to do.

## Verification status

**Verified end-to-end on real Qubes R4.3 hardware (2026-09/19), deployed through
the `mgmt-remote-debug` SSH channel, with `default_guivm = sys-gui-vnc`:**

- `fedora-43-xfce` was already in `qubes-templates-itl`;
- `install` (qubes-vm-guivm + XFCE) applied in the template, and lightdm ends up
  enabled and **starts at boot**;
- `create` built `sys-gui-vnc`, wrote the RPC policy + admin includes and the
  lightdm credential; `x11vnc` came up on `:5900` inside the qube;
- `web-create` / `web-install` / `web-configure` built the front end;
  `websockify` on `:6080`, `socat` on `127.0.0.1:5901`;
- `netfw` installed the double-NAT DNAT, and correctly detected that
  `sys-firewall` is a DispVM (persisting through `default-dvm`);
- from the LAN, `http://<sys-net-ip>:6080/vnc.html` returned the noVNC page, and
  `RFB 003.008` came back over socat → qrexec `ConnectTCP` → the GUI domain;
- a qube pointed at it (`qvm-prefs dev guivm sys-gui-vnc`) rendered its windows
  there (`qubes-guid -N dev`); `mgmt.gui-vnc.prefs` switched `default_guivm`
  without dropping SSH or stopping any qube.

Two real bugs were fixed from that first deploy (both in the committed states,
but worth knowing):

1. **`service.enabled` does not enable lightdm.** The unit carries
   `Alias=display-manager.service`, so `systemctl is-enabled` reports it enabled
   and Salt never creates `multi-user.target.wants/lightdm.service`; lightdm then
   does not start at boot and the GUI domain serves no VNC. `install.sls` now
   runs `systemctl enable lightdm` explicitly, guarded on that symlink.
2. **Template changes must be committed (template stopped) before an AppVM is
   started from it.** An AppVM started while the template is still running misses
   new files (the lightdm symlink above). The deploy sequence stops the template
   between `install` and `create`.

**Still unverified:** `teardown` (not exercised); and the backends' behaviour on
a machine whose `sys-firewall` is not the standard double-NAT path. The
`@tag:guivm-<qube>` policy lines were checked against Qubes source — the tag is
maintained by `qubes/ext/gui.py` — not merely assumed.

## Teardown

```sh
sudo qubesctl state.apply mgmt.gui-vnc.teardown
```

Reverts `default_guivm` to dom0, removes both policy files and the admin-include
blocks, then removes `sys-vncweb`, its template and `sys-gui-vnc`. Set
`cfg.gui_vnc.keep_qubes = True` to revoke access but keep the qubes.
