# mgmt.remote-debug

Deploy an SSH **jump qube** to drive this Qubes machine from your dev laptop:
run Salt in dom0, move files, and create/build qubes — over SSH on the LAN,
without ever putting sshd or network on dom0.

> **Development convenience with a real security cost.** Read
> [Security](#security) before deploying. dom0 never runs sshd; SSH terminates
> in a dedicated AppVM that reaches dom0 through qrexec.

## Table of Contents

*   [What it does](#what-it-does)
*   [Configure](#configure)
*   [Deploy](#deploy)
*   [Using it](#using-it)
*   [Troubleshooting](#troubleshooting)
*   [Security](#security)
*   [Teardown](#teardown)

## What it does

| State | Runs in | Purpose |
|-------|---------|---------|
| `create` | dom0 | create the networked jump qube (`mgmt-jump`) |
| `install` | template | install `openssh-server` in the jump qube's template |
| `configure` | jump qube | authorized_keys, hardened sshd, persist via rc.local |
| `dom0-access` | dom0 | qrexec policy so the jump qube can drive dom0 |
| `netfw` | dom0 (pushes to sys-net + sys-firewall via qvm-run) | nftables port-forward so the LAN can reach sshd |
| `teardown` | dom0 | revoke dom0 access and remove the jump qube |

## Configure

Everything is driven by the `cfg.remote_debug` block in `salt/config.jinja`:

```jinja
"remote_debug": {
  "qube": "mgmt-jump",
  "template": "debian-13-minimal",
  "label": "red",
  "authorized_keys": [
    "ssh-rsa AAAA... you@dev",       # your dev machine's public key
  ],
  "dom0_access": "whitelist",        # "whitelist" (safer) or "shell" (any command)
  "network": "portforward",          # "portforward" or "none"
  "ssh_port": 2333,                  # external port on sys-net's physical IP
  "netvm": "sys-firewall",
  "lan_subnet": "10.42.0.0/24",      # narrow to your real LAN
  # optional: "keep_qube": True,     # teardown revokes access but keeps the qube
},
```

- **`dom0_access: whitelist`** installs a `qubes.RemoteDebug` qrexec service that
  only runs an allow-listed set of commands (Salt + `qvm-create`/`run`/`copy`/
  `prefs` + `qubes-dom0-update`), enough to build Gentoo templates.
- **`dom0_access: shell`** installs a `qubes.VMShell` policy — the jump qube can
  run **any** dom0 command. Convenient, riskier (see [Security](#security)).

## Deploy

Order matters (create → install sshd → configure → dom0 access → port-forward),
and a brand-new qube can't be created and configured in one highstate pass, so
apply the targets in sequence from **dom0**:

```sh
# 1. Create the jump qube
sudo qubesctl state.apply mgmt.remote-debug.create

# 2. Install sshd in its template, then restart the qube to pick it up
sudo qubesctl --skip-dom0 --targets=debian-13-minimal state.apply mgmt.remote-debug.install
qvm-shutdown --wait mgmt-jump 2>/dev/null; qvm-start mgmt-jump

# 3. Configure sshd + your key inside the jump qube
sudo qubesctl --skip-dom0 --targets=mgmt-jump state.apply mgmt.remote-debug.configure

# 4. Install the dom0 access channel (whitelist service + policy)
sudo qubesctl state.apply mgmt.remote-debug.dom0-access

# 5. Port-forward through sys-net + sys-firewall (nftables).
#    Runs in dom0 and pushes the firewall script into both hops via qvm-run —
#    sys-net cannot run qubesctl (Qubes denies it the admin API by design).
sudo qubesctl state.apply mgmt.remote-debug.netfw
```

Find the address to SSH to — the **physical IP held by `sys-net`**:

```sh
qvm-run --pass-io sys-net 'ip -4 addr show | grep -v 127.0.0.1'
```

## Using it

On your dev machine, `ssh -p <ssh_port> user@<sys-net-physical-ip>`. Add a host
alias (`~/.ssh/config`):

```
Host qubes-jump
    HostName 192.168.1.50      # sys-net's physical IP
    Port 2333
    User user
    IdentityFile ~/.ssh/id_rsa
```

**Drive dom0** from the jump qube. In whitelist mode, call the service:

```sh
# from your Mac, one line:
ssh qubes-jump "echo 'qubesctl state.apply templates.gentoo-dev.create' | qrexec-client-vm dom0 qubes.RemoteDebug"
```

Add a helper on the jump qube (`~/.bashrc`) so it is one word:

```sh
dom0() { printf '%s\n' "$*" | qrexec-client-vm dom0 qubes.RemoteDebug; }
# then:  ssh qubes-jump "dom0 'qubesctl saltutil.sync_all'"
```

In **shell** mode, use `qubes.VMShell` instead of `qubes.RemoteDebug`.

**Move files** (Mac → jump → dom0/other qube):

```sh
# Mac -> jump qube
scp ./salt/... qubes-jump:~/incoming/

# jump qube -> another qube (e.g. a build qube)
ssh qubes-jump 'qvm-copy-to-vm gentoo-build ~/incoming/foo'

# jump qube -> dom0 (whitelisted qvm-run pull pattern)
ssh qubes-jump "dom0 'qvm-run --pass-io mgmt-jump \"cat ~/incoming/foo\" > /tmp/foo'"
```

**Build a Gentoo template** end to end (whitelist covers these):

```sh
ssh qubes-jump "dom0 'qvm-create --template debian-13-minimal --label black gentoo-build'"
ssh qubes-jump "dom0 'qvm-run --pass-io -- gentoo-build \"cd ~/qubes-builderv2 && ./qb ...\"'"
```

## Troubleshooting

Port-forwarding an external connection down to an AppVM runs against Qubes'
default isolation, so several independent things must all be right. If SSH
times out, work through these (the bundled `scripts/diagnose-netfw.sh`, run in
dom0, checks all of them and prints per-hop PASS/FAIL verdicts).

**The `dom0()` command returns empty / "looks broken".** The whitelist service
allows a **single command only — no shell pipes**. `dom0 'qvm-ls | head'` is
rejected (empty output); use `dom0 'qvm-ls --raw-list'` and pipe on your side.

**SSH times out — diagnose in this order:**

| Symptom (in dom0) | Cause | Fix |
|---|---|---|
| `qvm-run -u root mgmt-jump 'ip -o addr show'` shows **no eth0 / no IP** | jump has no network | Ensure `qvm-prefs mgmt-jump provides_network` is **False** (the `net` create flag wrongly sets it True), and that the template has `qubes-core-agent-networking` (minimal templates don't by default — `install` adds it). Then restart the jump. |
| jump **pings its gateway OK** but `sys-firewall -> jump:22` FAILs, and the sys-firewall neigh entry is `PERMANENT` | **stale ARP** — each jump restart changes its vif; a leftover neigh pins the dead vif | On sys-firewall: `ip neigh flush to <jump-ip>` (netfw now does this automatically on every firewall load). |
| jump `nft` input chain shows `policy drop; jump custom-input` and the custom-input accept **counter is 0** | inbound dropped by the jump, or the packet never arrived | If counter 0, the packet isn't arriving — it's the ARP/network issue above, not input. If packets hit the drop, the `custom-input tcp dport 22 accept` rule (added by `configure`) is missing. |
| conntrack on sys-firewall shows the flow **UNREPLIED with dst still `<sys-firewall-ip>:2333`** (not DNAT'd) | DNAT rule not matching | netfw matches `ip daddr <sys-firewall-ip>` (not `iifgroup`), which is reliable; re-run `state.apply mgmt.remote-debug.netfw`. |
| everything above passes but the handshake still hangs | missing SNAT | netfw adds a postrouting masquerade so replies route back; confirm `custom-snat-remotedebug` exists on both hops. |
| **works until you reboot, then re-applying the states "fixes" it every time** | something the states install is not actually running at boot | Check `/rw/config/remote-debug-boot.log` on each hop and on the jump: every boot appends one line. A line whose timestamp matches `uptime -s` means that qube self-configured; **no line means the script never ran at boot** and the manual re-apply is what installed the rules. See below for the two causes already found and fixed. |

**Two independent "lost after every reboot" bugs, both now fixed — check these
first if it happens again:**

1. **On the jump qube, `/rw/config/qubes-firewall-user-script` never runs.** It
   is executed by `qubes-firewall.service`, which carries
   `ConditionPathExists=/var/run/qubes-service/qubes-firewall` — that service is
   only enabled on qubes which PROVIDE network. A plain AppVM shows
   `Condition: start condition unmet` and the unit stays dead, so the
   `custom-input tcp dport 22 accept` rule was never installed at boot and
   inbound SSH was dropped. `configure` now installs that rule from
   **`/rw/config/rc.local`**, which `qubes-misc-post.service` runs on every
   AppVM boot, after `qubes-iptables.service` has created `table ip qubes`.

2. **On sys-net, the firewall script runs before the network exists.**
   `qubes-firewall.service` executes it seconds before NetworkManager has a DHCP
   lease, so `ip route` is empty and any rule installed conditionally on a
   resolved uplink is skipped. netfw now matches on `ip saddr`/`ip daddr` only,
   treats `iifname` as an optional tightening, and never `exit`s mid-script.
   Note the NetworkManager dispatcher hook it installs only self-heals where NM
   actually runs — on a ProxyVM like sys-firewall NM is **inactive**, so there
   the boot-time run is the only run.

**`qubesctl --targets=sys-net ... netfw` fails with "denied admin.vm.List".**
Expected — sys-net can't run qubesctl. netfw runs in **dom0** (no `--targets`)
and pushes to the hops via qvm-run: `sudo qubesctl state.apply mgmt.remote-debug.netfw`.

**After any change, re-package and re-deploy** — editing the repo does not
change `/srv/salt/slchris` until you run `setup.sh` again; `saltutil.sync_all`
does not copy files.

## Security

`dom0_access: shell` (`qubes.VMShell * mgmt-jump dom0 allow`) means a compromise
of the jump qube — which is networked and SSH-exposed — compromises **dom0 and
the whole system**. `whitelist` is much safer but note that allowing
`qvm-create` + `qvm-run` already grants broad control (you can run anything in
any qube); it merely stops *arbitrary dom0 shell*. Treat the jump qube as
sensitive regardless:

- Key-only SSH (enforced by `configure`), and narrow `lan_subnet` to your subnet.
- Shut the jump qube down when not debugging (`qvm-shutdown mgmt-jump`).
- Prefer `whitelist`; use `shell` only on a throwaway dev machine.

## Teardown

```sh
sudo qubesctl state.apply mgmt.remote-debug.teardown
```

Removes the dom0 policy + service (instantly revoking access) and the jump qube.
Set `cfg.remote_debug.keep_qube: True` in config.jinja to revoke access but keep the qube.
The port-forward scripts in sys-net/sys-firewall are removed by deleting
`/rw/config/qubes-firewall-user-script` in those qubes (or reset them there).
