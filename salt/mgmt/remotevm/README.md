# mgmt.remotevm

Register **RemoteVMs** (Qubes Air, R4.3+) — remote qubes reachable through a
relay qube over SSH — aligning with the official RemoteVM primitive
(`relayvm` / `transport_rpc` / `remote_name`) instead of a bespoke tunnel.

> **Experimental.** RemoteVM landed in Qubes OS R4.3 as an experimental Qubes
> Air feature (#9015). Exact `qvm-create`/policy behaviour may still shift; the
> steps below are written against the R4.3 core-admin `RemoteVM` class and the
> official SSH-transport example, and are marked where real-hardware
> verification is needed.

## What it does

| State | Runs in | Purpose |
|-------|---------|---------|
| `create` | dom0 | create a `RemoteVM` per target; set `relayvm` / `transport_rpc` / `remote_name` |
| `relay` | relay qube | install the `qubesair.SSHProxy` transport service + `~/.ssh/config` |
| `policy` | dom0 | local qrexec policy: which local qubes may call which services on the RemoteVMs |
| `teardown` | dom0 | remove the local policy and the RemoteVM definitions |

How a call flows (see [qubes-air/docs/remotevm-alignment.md](https://github.com/slchris/qubes-air/blob/main/docs/remotevm-alignment.md)):

```
local-qube ──qrexec──▶ relay (mgmt-jump) ──qubesair.SSHProxy(ssh)──▶ remote host ──qrexec-client-vm──▶ remote-qube
       (local dom0 policy)                                                 (remote dom0 policy)
```

The relay defaults to the **remote-debug jump qube** (`mgmt-jump`), so you do
not run two relays. `create` sets the RemoteVM's `relayvm` to it; the core
`Relay` extension then writes the `/remote/<local_name>` QubesDB mapping when the
relay **starts**, which the transport service reads to find the remote name.

## Configure

Everything is driven by the `cfg.remotevm` block in `salt/config.jinja`:

```jinja
"remotevm": {
  "relay": "mgmt-jump",               # LocalVM relay (reuses remote-debug jump)
  "transport_rpc": "qubesair.SSHProxy",
  "targets": [
    {"local_name": "remote-dev", "remote_name": "dev", "host": "10.42.0.50"},
  ],
  "allowed_sources": ["@anyvm"],      # local qubes allowed to call out
  "services": [
    {"name": "qubes.FileCopy", "action": "ask"},
  ],
},
```

- **`targets[].host`** is the SSH destination the *relay* uses to reach the
  remote host running `qrexec-client-vm` (the Remote-Relay). It becomes a `Host`
  entry in the relay's `~/.ssh/config`.
- **`services`** is the allow-list of qrexec services the local side may invoke
  on the RemoteVMs. Keep it tight — each entry punches a cross-machine hole.
- If you change **`relay`**, also update the target qube in `relay.top` and
  `init.top` (Salt tops match a literal qube name).

## Prerequisites

- **Relay qube exists and is networked.** By default deploy `mgmt.remote-debug`
  first so `mgmt-jump` exists. The relay needs an SSH client (install
  `openssh-client` in its template; `relay` adds a fallback) and SSH key auth to
  each `host`.
- **Remote side is set up** (on the remote host / Remote-QubesOS): it runs
  `qrexec-client-vm`, and — for the remote dom0 to resolve the source — the
  local source qube is registered there as a RemoteVM referencing it. This
  formula configures the **local** side only.

## Deploy

Apply from **dom0** in order (create → relay → policy):

```sh
# 1. Create the RemoteVMs and wire relayvm/transport_rpc/remote_name
sudo qubesctl state.apply mgmt.remotevm.create

# 2. The /remote QubesDB mapping is written when the relay starts, so restart
#    the relay if it was already running.
qvm-shutdown --wait mgmt-jump 2>/dev/null; qvm-start mgmt-jump

# 3. Install the transport service + ssh config inside the relay
sudo qubesctl --skip-dom0 --targets=mgmt-jump state.apply mgmt.remotevm.relay

# 4. Install the local qrexec policy
sudo qubesctl state.apply mgmt.remotevm.policy
```

## Verify

On real Qubes OS R4.3 hardware (this formula was authored + linted only; it has
not been run end-to-end — no remote host was available):

```sh
# The RemoteVM exists and has the three properties set
qvm-prefs remote-dev relayvm            # -> mgmt-jump
qvm-prefs remote-dev transport_rpc      # -> qubesair.SSHProxy
qvm-prefs remote-dev remote_name        # -> dev

# The relay saw the mapping after (re)start
qvm-run --pass-io mgmt-jump 'qubesdb-read /remote/remote-dev'   # -> dev

# The transport service is installed in the relay
qvm-run --pass-io mgmt-jump 'ls -l /etc/qubes-rpc/qubesair.SSHProxy'

# Policy is present
cat /etc/qubes/policy.d/30-remotevm.policy

# End-to-end (needs the remote host reachable + remote-side policy): call an
# allowed service on the RemoteVM from an allowed local qube and confirm it runs
# on the remote host.
```

> Points to confirm on hardware (documented in the qubes-air alignment doc):
> the exact `qvm-create --class RemoteVM` invocation, whether `qubesair.SSHProxy`
> ships with the distro or must be provided (this formula provides it), and the
> precise RemoteVM policy rule syntax.

## Security

- Every entry in `services` is a hole across machines. Prefer `ask` over `allow`
  and narrow `allowed_sources` from `@anyvm` to specific qubes.
- The relay can misrepresent which of *its own* source qubes a request came
  from, but not qubes that do not route through it; the remote dom0 re-checks
  policy. For stronger guarantees, end-to-end verification would be needed.
- The relay is networked and reused from remote-debug — treat it as sensitive
  and shut it down when idle.

## Teardown

```sh
sudo qubesctl state.apply mgmt.remotevm.teardown
```

Removes the local policy (instantly revoking access) and the RemoteVM
definitions. Set `cfg.remotevm.keep_qubes: True` to keep the definitions. The
transport service + `~/.ssh/config` in the relay are harmless without the
RemoteVMs; remove them by hand if desired.
