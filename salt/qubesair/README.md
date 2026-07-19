<!--
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT
-->

# qubesair — the Qubes Air console template and AppVM

Builds a **dedicated template** and the **console AppVM** on it:

```
debian-13-minimal ──clone──> tpl-qubesair ──template of──> qubesair-console
                             (terraform,                   (PVE token, agent CA
                              dnsmasq, git,                 key, terraform state,
                              sqlite3, ...)                 SQLite database)
                                                                  │ netvm
                                                            sys-tailscale ── sys-firewall ── sys-net ── 10.31.0.0/24
```

## Why not just reuse `mgmt-jump`

`mgmt-jump` accepts **inbound SSH** (`cfg.remote_debug`, port-forwarded from the
LAN). A qube that anyone on the LAN can knock on must not also hold the PVE API
credentials, the agent CA private key, and the terraform state that together can
rebuild the entire remote fleet. Those two roles get two qubes.

That is a design constraint, not a preference, and it is enforced in three
places: no `openssh-server` in the template, no `custom-input` accept rule
anywhere in this module (unlike `mgmt.tailscale` and `mgmt.remote-debug`), and
the console binding loopback by default. Adding any one of them back re-creates
exactly the problem this module exists to avoid.

## Layout

| File | Runs in | Does |
|---|---|---|
| `clone.sls` | dom0 | clones `cfg.qubesair.template_source` → `cfg.qubesair.template` |
| `install.sls` | `tpl-qubesair` | terraform + provider mirror + the console's packages |
| `create.sls` | dom0 | template prefs, the AppVM, private-volume size |
| `configure.sls` | `qubesair-console` | split-horizon DNS (qube networking) |
| `console.sls` | `qubesair-console` | the console **service** — binary, unit, env, data layout (owned separately) |

`configure.sls` and `console.sls` are deliberately disjoint: different state-ID
prefixes, different files, different `rc.local` marker blocks, and **no shared
directory**. Two `file.directory` states on one path with different modes flip it
back and forth on every apply, so this state keeps its only directory at
`/rw/config/qubesair-net/` and leaves the console's data layout entirely to
`console.sls`.

All settings come from `cfg.qubesair` in `salt/config.jinja`. Every key is read
through `.get()` with a default, so the ones that block does not currently
define — `dns_domains`, `service_user`, `terraform_providers`,
`terraform_mirror_dir`, `terraform_cli_config` — are optional and can be added
later without touching these states.

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
#    exists, resolves internal names and has terraform — and runs no console.
#    Every step above reports success either way, so the omission is invisible.
sudo qubesctl --skip-dom0 --targets=qubesair-console state.apply qubesair.console
```

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
only on 443 cannot be provisioned at all — a `terraform apply` gets as far as
cloning the VM and then fails, leaving a half-built qube behind.

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

The console reads the key at job time and passes it to terraform as a
`TF_VAR_`, so it never lands in the terraform root or in state — the same rule
the API token follows. Rotating it needs no restart.

## How terraform gets in, and why that way

terraform is **not packaged in Debian** and is absent from
`debian-13-minimal`. The console does not embed it, it `exec`s it, so this is a
hard prerequisite: without it every start/stop fails at exec time with
`executable file not found` — *after* the API call has already reported success.

**Chosen: the pinned release zip from `releases.hashicorp.com`, verified against
a SHA256 that ships in this repo.** `install.sls` downloads to a temp dir,
checks the digest, and only then installs; a failed check leaves nothing behind.

The two alternatives, and why not:

- **HashiCorp's apt repo** is GPG-signed but **floats** — `apt-get install
  terraform` gives whatever is newest that day, so two templates built a week
  apart drive the same cluster with different terraform and nothing records
  which. It also has no CN mirror; this repo already dropped VS Code from
  `templates.dev.install` for precisely that failure mode.
- **The LAN artifact store at `10.31.0.2`** is fast and always reachable, but
  serves plain HTTP with no TLS and no signature
  ([bootstrap-design.md §6.4](../../../project/qubes-air/docs/bootstrap-design.md)).
  That is *acceptable* — but only because the digest travels a **different,
  trusted channel** (this repo → `scripts/setup.sh` → dom0 `/srv/salt`) than the
  bytes do, which is the same argument that makes the agent `.deb` safe. It is
  not *preferable*, because it adds a publish step whose failure mode is a stale
  binary served under the right name. Point `terraform_url` there when upstream
  is unusable; the digest check is unchanged and becomes the **only** thing
  between the LAN and root on the cluster.

`cfg.qubesair.terraform_sha256` is currently **empty**. Rather than install
unverified, `install.sls` falls back to a small built-in map of digests taken
from HashiCorp's own `SHA256SUMS` (1.9.8 and 1.15.8), and **hard-fails** for any
other version. Paste the real digest into `config.jinja` to make this explicit:

```bash
curl -s https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_SHA256SUMS | grep linux_amd64
# 186e0145f5e5f2eb97cbd785bc78f21bae4ef15119349f6ad4fa535b83b10df8  terraform_1.9.8_linux_amd64.zip
```

### Provider mirror

`bpg/proxmox` is seeded into a filesystem mirror at
`/usr/share/terraform/providers` so the provider that holds the PVE token comes
from a byte-for-byte pinned copy, and so `terraform init` works when the
registry is slow or blocked. The pinned digest
(`6ed47bc0…`, v0.111.1) is the same value already recorded as a `zh:` hash in
qubes-air's `terraform/.terraform.lock.hcl` — a lock file's `zh:` hash *is* the
release zip's SHA256, so this number is corroborated by a file the console repo
already trusts.

Only mirrored providers are pinned; everything else still resolves from the
registry. **Note:** `qubes-air/terraform/main.tf` also declares
`hashicorp/google` and `hashicorp/aws`, so `terraform init` still needs
`registry.terraform.io` unless those are removed or added to
`cfg.qubesair.terraform_providers`.

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
public DNS (e.g. `registry.terraform.io` for `terraform init`) depend on the
internal resolver recursing for the whole internet; if it does not, it answers
NXDOMAIN, **glibc treats that as a real answer and never tries the next
nameserver**, and public name resolution breaks in a way that looks like a
network fault. The zone list is derived from `pve_endpoint` (exact host + parent
zone) and overridable with `cfg.qubesair.dns_domains`.

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
terraform state, agent identities) already lives under `/rw` via
`cfg.qubesair.data_dir` and needs no bind mount at all.

## Verified end-to-end on hardware (2026-07)

The whole chain was run on the real Proxmox "infra" cluster, not just linted:
`qubesair.clone` → `install` (terraform + provider from the LAN mirror) →
`create` (the AppVM + the ConnectTCP policy) → `console` (binary + web UI + SSH
key). From the browser in `slchris_homelab`, over `qvm-connect-tcp`, a qube was
created through the UI; terraform cloned template 901, the cloud-init snippet
uploaded over SSH, the agent installed from the artifact store, and the console
probed it to `agent_health: healthy`. The provisioning log streamed live in the
card the whole time.

What is NOT yet exercised: registering that VM as a dom0 RemoteVM and calling it
over cross-machine qrexec — see
[qubes-air/docs/remotevm-alignment.md §5.5](https://github.com/slchris/qubes-air/blob/main/docs/remotevm-alignment.md).
The checks below are the per-qube DNS/network layer, still worth running on a
fresh console qube.

## Verify

```bash
# in qubesair-console
dig +short pve.infra.plz.ac            # -> 10.31.0.253, via 10.31.0.252
cat /etc/resolv.conf                   # -> nameserver 127.0.0.1
terraform version                      # -> Terraform v1.9.8
sudo journalctl -t qubesair-dns -b     # what the boot-time run decided
ls -ld /rw/config/qubesair             # -> drwx------
curl -sS https://pve.infra.plz.ac/     # certificate validates against the NAME
```

A useful negative check — this qube must have nothing listening inbound:

```bash
ss -lntp                               # no sshd, console on 127.0.0.1 only
```

## What these four states do NOT do

The console **service** — binary, systemd unit, env files, secrets, database and
terraform working tree — is `console.sls`, not these. What is provided here is
the platform it runs on: the template with terraform in it, the qube, and DNS.

### Reconciled with `console.sls`

Written separately, so the two disagreed at first. Both mismatches are fixed;
recorded here because each failed in a way that reads as success.

1. **Config schema.** `console.sls` reads flat `cfg.qubesair.*`, matching
   `config.jinja`. The earlier nested `cfg.qubesair.console.*` reads all fell
   through to built-in defaults — including `enabled`, defaulting to `False`, so
   the state rendered nothing but a disabled notice while reporting success.
2. **`TF_CLI_CONFIG_FILE`.** The unit sets `HOME` under `data_dir` with
   `ProtectHome=yes`, so terraform never sees a `$HOME/.terraformrc` and would
   have ignored the pinned provider mirror that `qubesair.install` seeds —
   silently reaching for the public registry instead. The unit now points at the
   mirror config explicitly.


## Enabling orchestration

The module ships `orchestrator_enabled: False`, so a first apply gives a console
that runs, serves its API and probes agents — but cannot create qubes. That is
deliberate: the terraform roots live in the qubes-air repo, not here, and a
console configured to orchestrate without them fails at every start.

Turning it on is three steps and one of them is manual by nature — `terraform
init` fetches providers, which no salt state should be doing on your behalf:

```sh
# 1. Copy the terraform root from the qubes-air repo into the console qube
#    (qvm-copy from wherever you keep it, then move it into place):
#      mv ~/QubesIncoming/<src>/terraform /rw/config/qubesair/terraform

# 2. Initialise it. NOTE: this still needs registry access, and the reason is
#    not obvious — terraform/main.tf declares hashicorp/google, hashicorp/aws
#    and hashicorp/random alongside bpg/proxmox, and required_providers is
#    STATIC: init downloads all four even with enable_gcp_zone and
#    enable_aws_zone false. Only proxmox is in the seeded mirror, so the qube
#    needs a route to registry.terraform.io for this one command.
#
#    Budget the disk: google and aws are on the order of a hundred megabytes
#    each, against ~1.9G free on /rw. If that is too tight, trim the unused
#    provider blocks from main.tf before copying it in — the gcp/aws modules
#    are skeletons that create nothing today.
cd /rw/config/qubesair/terraform && terraform init

# 3. Flip cfg.qubesair.orchestrator_enabled to True, redeploy the salt tree,
#    and re-apply:
sudo qubesctl --skip-dom0 --targets=qubesair-console state.apply qubesair.console
```

The preflight checks all three and names which one is missing, so a mistake here
fails at start with a specific message rather than at the first attempt to
create a qube.
