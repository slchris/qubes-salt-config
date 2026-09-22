<!--
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT
-->

# qubesair — the Qubes Air console template and AppVM

Builds a **dedicated template** and the **console AppVM** on it:

```
debian-13-minimal ──clone──> tpl-qubesair ──template of──> qubesair-console
                             (sqlite3,                     (PVE token, agent CA
                              dnsmasq, dig,                 key, qube_infra,
                              ssh client, ...)              SQLite database)
                                                                  │ netvm
                                                            sys-tailscale ── sys-firewall ── sys-net ── 10.31.0.0/24
```

The console is a self-contained Go binary: it drives provider APIs with Go's own
HTTP/TLS stack (no terraform, no provider mirror, no registry access), and it
execs nothing to provision.

## Why not just reuse `mgmt-jump`

`mgmt-jump` accepts **inbound SSH** (`cfg.remote_debug`, port-forwarded from the
LAN). A qube that anyone on the LAN can knock on must not also hold the PVE API
credentials, the agent CA private key, and the provider credentials that together
can rebuild the entire remote fleet. Those two roles get two qubes.

That is a design constraint, not a preference, and it is enforced in three
places: no `openssh-server` in the template, no `custom-input` accept rule
anywhere in this module (unlike `mgmt.tailscale` and `mgmt.remote-debug`), and
the console binding loopback by default. Adding any one of them back re-creates
exactly the problem this module exists to avoid.

## Layout

| File | Runs in | Does |
|---|---|---|
| `clone.sls` | dom0 | clones `cfg.qubesair.template_source` → `cfg.qubesair.template` |
| `install.sls` | `tpl-qubesair` | the console's runtime packages |
| `create.sls` | dom0 | template prefs, the AppVM, private-volume size |
| `configure.sls` | `qubesair-console` | split-horizon DNS (qube networking) |
| `console.sls` | `qubesair-console` | the console **service** — binary, unit, env, data layout (owned separately) |
| `backup.sls` | `qubesair-console` | the database backup — binary, service, timer, one run per boot |

`configure.sls` and `console.sls` are deliberately disjoint: different state-ID
prefixes, different files, different `rc.local` marker blocks, and **no shared
directory**. Two `file.directory` states on one path with different modes flip it
back and forth on every apply, so this state keeps its only directory at
`/rw/config/qubesair-net/` and leaves the console's data layout entirely to
`console.sls`.

All settings come from `cfg.qubesair` in `salt/config.jinja`. Every key is read
through `.get()` with a default, so optional ones — `dns_domains`,
`service_user`, `net_dir` — can be added later without touching these states.

## Deploy

Order matters across qubes. `install` must land on the template **before**
`create` builds the AppVM from it, and `configure` needs a running qube.

```bash
# 0. prerequisites: cfg.qubesair.enabled = True, and — because
#    cfg.qubesair.netvm defaults to sys-tailscale — mgmt.tailscale already
#    deployed. Set netvm to sys-firewall to skip that.
sudo qubesctl top.enable qubesair.clone  && sudo qubesctl state.apply qubesair.clone
sudo qubesctl top.disable qubesair.clone

sudo qubesctl --skip-dom0 --targets=tpl-qubesair state.apply qubesair.install

sudo qubesctl top.enable qubesair.create && sudo qubesctl state.apply qubesair.create
sudo qubesctl top.disable qubesair.create

qvm-start qubesair-console
sudo qubesctl --skip-dom0 --targets=qubesair-console state.apply qubesair.configure

# 5. Install the console binary and its service. Without this step the qube
#    exists, resolves internal names and has the provider packages — and runs no
#    console. Every step above reports success either way, so the omission is
#    invisible.
sudo qubesctl --skip-dom0 --targets=qubesair-console state.apply qubesair.console
```

### Backups (optional, but a console whose database exists once is a console you can lose)

`qubesair.backup` deploys the snapshot/encrypt/prune job for the console
database. It is **off until you finish three steps**, and it says so rather than
rendering a timer that backs nothing up:

1. **Mount the off-host medium** somewhere and put it in `cfg.qubesair.backup.offhost_dir`.
   The unit declares `RequiresMountsFor` it, so an unmounted medium fails the
   backup instead of leaving the only copy on the disk the backup exists to
   survive. Whether that is LUKS, `qvm-block`, or a network mount is your call —
   this state does not guess.
2. **Build and pin the binary.** `qubes-air-backup` is built from the qubes-air
   Go source and nothing publishes it yet:

   ```bash
   cd console/backend
   CGO_ENABLED=1 GOOS=linux GOARCH=amd64 \
     go build -trimpath -ldflags="-s -w" -o qubes-air-backup ./cmd/qubes-air-backup
   cp qubes-air-backup <this repo>/salt/qubesair/files/
   shasum -a 256 <this repo>/salt/qubesair/files/qubes-air-backup
   ```

   Put the digest in `cfg.qubesair.backup.binary_sha256`; the state hard-fails
   without it, for the same reason the console binary is pinned.
3. **Create the passphrase once, inside the console qube** — and copy it to the
   off-host medium. It is not recoverable from the archives:

   ```bash
   # in qubesair-console
   printf 'QUBES_AIR_BACKUP_PASSPHRASE=%s\n' "$(head -c 32 /dev/urandom | base64)" \
     > /rw/config/qubesair/backup.env && chmod 0600 /rw/config/qubesair/backup.env
   ```

   The state enforces that file's mode and owner and refuses to run while it is
   missing or empty, but it never writes it: a state that owned the passphrase
   would replace the key on some future apply and orphan every archive written
   before it.

Then set `cfg.qubesair.backup.enabled: True` and apply:

```bash
sudo qubesctl --skip-dom0 --targets=qubesair-console state.apply qubesair.backup

# verify, in the qube — run it now rather than the night you need it
systemctl list-timers qubes-air-backup.timer
systemctl start qubes-air-backup.service
journalctl -u qubes-air-backup -n 50
ls -lt /secure/offhost/*.qab | head
```

Two things worth knowing before trusting it:

- **The timer alone would not be enough.** It cannot fire while this AppVM is
  down, and `Persistent=true` does not rescue that here: its missed-run stamp
  lives under `/var/lib/systemd/timers/`, on the root volume this AppVM discards
  on every shutdown. So the state also runs one backup per boot
  (`cfg.qubesair.backup.run_at_boot`). Set that False only if this qube really
  does run at the scheduled time.
- **Copy archives back in with `cp -p`.** `prune` orders by mtime, so copies that
  lose their timestamp look like the newest archives and push the real newest one
  out of the keep window.

## Opening the console

The console serves its UI and its API on **loopback inside its own qube**, and
there is **no browser in that qube** — the package list in `install.sls` is short
on purpose, because this is the qube holding the PVE token and the fleet CA.
Installing a browser here to "just look at the page" would undo the reason the
qube exists.

A browser in another qube reaches it over **qrexec**, not over the network:

```sh
# In slchris_homelab (or any qube listed in cfg.qubesair.ui_clients):
qvm-connect-tcp 8080:qubesair-console:8080
```

Leave that running and open <http://127.0.0.1:8080/> in that qube's browser.
Nothing is exposed on the network, no port is opened on the console qube, and
dom0 authorises the channel per source qube via
`/etc/qubes/policy.d/30-qubesair-console.policy` (written by `qubesair.create`
from `cfg.qubesair.ui_clients`).

To allow another qube, add it to `ui_clients` and re-apply `qubesair.create` —
not `@anyvm`. Every qube that can reach this port can drive the whole fleet once
a token is pasted in on the other end.

### First load: paste the API token

The page loads without a token, and every `/api/v1` call returns **401** until
one is set. That is not a fault: `qubesair.console` generates a token on first
apply and it is never transmitted anywhere.

```sh
# In dom0 — the file is mode 0600 inside the qube:
qvm-run --pass-io -u root qubesair-console \
    'grep QUBES_AIR_API_TOKEN /rw/config/qubesair/secrets.env'
```

Paste the value into the console's **Settings** view. It is stored in that
browser's `localStorage` under `qubesair.apiToken` and sent as
`Authorization: Bearer …` on every request, so it is entered once per browser.

The token is deliberately not injected into the page at build or deploy time:
anything that put it where the frontend could read it automatically would also
hand it to anyone who can open the page.

### If the page does not load

| Symptom | Cause |
|---|---|
| `qvm-connect-tcp` exits with "Request refused" | the calling qube is not in `ui_clients`, or `qubesair.create` has not been re-applied since it was added |
| Connection refused on 127.0.0.1:8080 | the console is not running in its qube — check `systemctl status qubes-air-console` there |
| Page loads, everything shows an error | no API token set yet, or the wrong one — see above |
| Blank page, 404 on `/` | the frontend was not delivered: `console_web_source` / `console_web_sha256` are unset, so the console is serving its API only |

## Provisioning needs SSH to the PVE nodes

Not optional, and not obvious: uploading a qube's cloud-init snippet writes
`/var/lib/vz/snippets/` **on the node over SSH**. The PVE API has no endpoint
for it. That snippet carries the per-qube agent identity, so a cluster reachable
only on 443 cannot be provisioned at all — a provision gets as far as cloning
the VM and then fails, leaving a half-built qube behind. (The alternative is
shared-storage identity delivery, where the console writes the snippet to a
datastore the nodes already read.)

The key is generated **in the console qube** and never leaves it. `qubesair.console`
creates the directory but deliberately does not create the key: a re-apply that
replaced a key whose public half is installed on the cluster would break
provisioning at the next job, with an authentication error naming the node
rather than salt.

```sh
# Once, in the console qube (as the service user):
ssh-keygen -t ed25519 -N '' -C qubesair-console-to-pve \
    -f /rw/config/qubesair/ssh/pve_ed25519
cat /rw/config/qubesair/ssh/pve_ed25519.pub
```

Install that public key as `root` on the PVE nodes. On a **clustered** PVE,
`/root/.ssh/authorized_keys` is shared through `/etc/pve`, so adding it on one
node covers all of them — verify rather than assume, since that is a property of
the cluster and not of this formula:

```sh
# On one node:
echo 'ssh-ed25519 AAAA... qubesair-console-to-pve' >> /root/.ssh/authorized_keys

# From the console qube, against a node the scheduler might actually pick:
ssh -i /rw/config/qubesair/ssh/pve_ed25519 root@<node-ip> hostname
```

The console reads the key at job time, so it never lands in any generated config
or record. Rotating it needs no restart.

## DNS

The console must resolve `pve.infra.plz.ac`. Qubes' default forwarders
(`10.139.1.1/.2`) do not; the internal resolver `10.31.0.252` does. Pointing
`pve_endpoint` at `10.31.0.253` instead would throw away hostname validation of
a valid Let's Encrypt certificate on the one connection carrying the PVE API
token — so the *name* has to keep working.

**Implemented as a local `dnsmasq` doing split-horizon forwarding**, not as a
rewritten `resolv.conf` and not as an `/etc/hosts` entry:

```
pve.infra.plz.ac, infra.plz.ac  ->  10.31.0.252
everything else                 ->  whatever Qubes gave this qube
```

`resolv.conf` can only say "ask these servers, in order" — it cannot say "ask
THIS server for THAT zone". Handing *every* query to `10.31.0.252` would make
public DNS depend on the internal resolver recursing for the whole internet; if
it does not, it answers NXDOMAIN, **glibc treats that as a real answer and never
tries the next nameserver**, and public name resolution breaks in a way that
looks like a network fault. The zone list is derived from `pve_endpoint` (exact
host + parent zone) and overridable with `cfg.qubesair.dns_domains`.

### How it survives a reboot

An AppVM's root volume is reset on every boot, and Qubes regenerates
`/etc/resolv.conf` from the netvm's QubesDB entries — so nothing under `/etc`
can simply be edited once.

`configure.sls` writes `/rw/config/qubesair-net/setup-dns.sh` (persistent) and
marker-merges a call to it into `/rw/config/rc.local`, the same convention
`mgmt.tailscale.configure` uses. On every boot the script:

1. reads the upstreams Qubes just configured (**not** hardcoded `10.139.1.1/.2`
   — those are the netvm's business and a frozen copy breaks the day they
   change), caching them to `/rw` so a salt re-apply still works when
   `resolv.conf` already points at loopback;
2. generates `/etc/dnsmasq.d/10-qubesair.conf` with `no-resolv` (without it
   dnsmasq would read the `resolv.conf` we are about to point at *dnsmasq* — a
   query loop) plus the split-horizon and upstream `server=` lines;
3. restarts dnsmasq and **proves it answers** with `dig` before touching
   `resolv.conf`. If it never answers, `resolv.conf` is left as Qubes made it —
   degrading to "internal names do not resolve" rather than "no DNS at all";
4. writes `nameserver 127.0.0.1` **only**. Keeping the originals as a "fallback"
   would not be one: glibc stops at the first *answer*, and an upstream that
   does not know `infra.plz.ac` answers NXDOMAIN. A dnsmasq hiccup would not
   fail over, it would silently start returning "no such host" for PVE.

`dnsmasq` is bound to loopback from the first second of boot
(`00-qubesair-base.conf`, shipped in the template) so this qube is never briefly
an open resolver on its network-facing interface.

### Why not bind-dirs here

`mgmt.tailscale` uses bind-dirs because `/var/lib/tailscale` is *state* that
must be preserved byte-for-byte. Here the affected files (`resolv.conf`,
`dnsmasq.d/*`) are **derived** from live QubesDB values, so regenerating them at
boot is more correct than restoring a snapshot — a bind-dir'd `resolv.conf`
would pin yesterday's netvm. Everything that is genuinely *state* (database,
provider resource records, agent identities) already lives under `/rw` via
`cfg.qubesair.data_dir` and needs no bind mount at all.

## Verification history

The DNS/network layer was run on real hardware (2026-07). The provisioning path
was verified end to end at that time with the terraform-based console; the
terraform-free provider adapter has separately passed a real provider lifecycle
smoke (provision → suspend → resume → purge), and its end-to-end agent-health
path is tracked in
[qubes-air/docs/provider-design.md](https://github.com/slchris/qubes-air/blob/main/docs/provider-design.md).

## Verify

```bash
# in qubesair-console
dig +short pve.infra.plz.ac            # -> 10.31.0.253, via 10.31.0.252
cat /etc/resolv.conf                   # -> nameserver 127.0.0.1
sudo journalctl -t qubesair-dns -b     # what the boot-time run decided
ls -ld /rw/config/qubesair             # -> drwx------
curl -sS https://pve.infra.plz.ac/     # certificate validates against the NAME
```

A useful negative check — this qube must have nothing listening inbound:

```bash
ss -lntp                               # no sshd, console on 127.0.0.1 only
```

## What these states do NOT do

The console **service** — binary, systemd unit, env files, secrets, database and
resource records — is `console.sls`, not these. What is provided here is the
platform it runs on: the template with its runtime packages, the qube, and DNS.

### Reconciled with `console.sls`

Written separately, so the two disagreed at first. The mismatch is fixed;
recorded here because it failed in a way that reads as success.

1. **Config schema.** `console.sls` reads flat `cfg.qubesair.*`, matching
   `config.jinja`. The earlier nested `cfg.qubesair.console.*` reads all fell
   through to built-in defaults — including `enabled`, defaulting to `False`, so
   the state rendered nothing but a disabled notice while reporting success.

## Enabling orchestration

Set `cfg.qubesair.orchestrator_enabled` to True (it ships that way in the fleet
config) and the console provisions through the zone's provider adapter. There is
no terraform root to copy and no `init` to run. What provisioning does require:

1. a Proxmox **zone** in the console with a credential configured;
2. the console's PVE SSH public key installed on the nodes, or shared-storage
   identity delivery configured (see "Provisioning needs SSH to the PVE nodes").

A zone with no registered adapter is refused at operation time rather than
silently doing nothing.

## Running commands on remote hosts (`qubesair.Exec` / `qubesair.FileCopy`)

Provisioning needs nothing from you here. Running arbitrary commands or copying
files on a provisioned host is a **separate** capability, and it is off until you
name the paths:

```jinja
"agent_exec_allow": ["/usr/bin/qm", "/usr/sbin/pvesm"],   # absolute PROGRAMS
"agent_filecopy_roots": ["/var/lib/vz/dump"],             # absolute DIRECTORIES
```

Both are empty by default and **empty means the service is disabled inside the
guest**: the agent rejects every Exec/FileCopy call rather than allowing all of
them. `console.sls` writes them into the console's environment (`QUBES_AIR_EXEC_ALLOW`
/ `QUBES_AIR_FILECOPY_ROOTS`, colon-separated), the console delivers them to each
new agent with its cloud-init identity, and the agent validates them again on its
own side. `/` is refused as a FileCopy root. An entry containing `:` is refused —
that separator is the wire format, and a path that contains one could not be
delivered unambiguously.

The console validates both lists at startup, so a typo fails the service rather
than silently delivering an allowlist nobody can use.
