# Qubes Air fixed desktop stream

This stage wires the current direct-agent desktop protocol into the authoritative
Qubes Salt deployment. It does not deploy a remote desktop image, create a Qube,
enable a client automatically, or establish production GUI acceptance.

Acceptance criteria:

- `grpc-csr-relay` installs the fixed `qubesair.ConnectDesktop` handler under its
  existing root-owned persistent runtime and restores its qrexec link at boot.
- The handler takes one local `remote-*` name, validates the endpoint from
  QubesDB, and sends only the fixed `desktop` selector to `relay-call -stream`.
  Invalid names, extra arguments, missing identity and invalid endpoints fail
  before dispatch. Agent mTLS still authenticates role, target and revocation.
- `grpc-policy` grants desktop access only for explicitly configured exact
  source/target pairs. No grants means deny; invalid configuration fails before
  replacing policy. A grant cannot choose a port, socket path or command.
- The old TCP handler refuses port 10005, matching the agent's fixed Unix
  desktop boundary. Other permitted TCP services retain their existing scope.
- Rendering, negative handler cases, persistent boot wiring, ShellCheck,
  Salt/YAML lint and all deployment contracts pass before submission.

The guest must meet the encrypted HOME and Xpra requirements documented in
[Qubes Air's encrypted HOME record](https://github.com/slchris/qubes-air/blob/main/docs/reviews/2026-10-24-encrypted-desktop-home.md).
The deployed `relay-call` must support the fixed `desktop` selector. Source
changes alone do not update its pinned artifact or grant access to a client.

## Configuration and deployment

Use `remotevm.grpc.csr.desktop_grants`, initially empty. Each entry grants an
already listed `allowed_callers` VM interactive control of one exact local
RemoteVM's desktop. For example, add `work-client` to the existing callers and
add this entry to the existing CSR configuration:

```jinja
"desktop_grants": [
  {"source": "work-client", "target": "remote-example"},
],
```

Names must use the repository's Qubes name grammar and be at most 31 characters;
targets must start with `remote-` and have a nonempty suffix. At most 32 grants
are accepted. The generated allow matches the exact `+remote-example` argument
and the configured relay, followed by a deny for other VM callers/targets.
This uses Qubes' [exact service argument policy](https://doc.qubes-os.org/en/r4.3/developer/services/qrexec.html).
The dom0 administrator remains trusted; this policy is not an isolation boundary
against administrative calls.

Prepare and SHA256-pin a current Air `relay-call` artifact before enabling a
grant. The copies of both handlers in this change match Air commit
`72e41bf4c1b9219eca836af039bd2f06a9977394`. Existing binary source/hash configuration
is preserved. Preview and then apply the relay state and policy through the
existing authority:

```bash
sudo qubesctl --skip-dom0 --targets=<relay> state.apply mgmt.remotevm.grpc-csr-relay test=True
sudo qubesctl state.apply mgmt.remotevm.grpc-policy test=True
```

After reviewing the rendered states, apply the same commands without `test=True`.
The new qrexec service forwards to the agent's fixed Unix socket through mTLS;
it opens no new remote application TCP listener. `ConnectTCP` continues to serve
its existing permitted ports, except 10005 is refused before endpoint lookup.

Removing a grant and reapplying policy denies new requests. Existing streams
must be closed separately on the client or during an approved desktop-session
restart. Removing a policy file is not a rollback: it may expose later fallback
rules. Keep the explicit deny installed. The persistent handler can remain
installed without any grants.

## Validation scope

Local contracts exercise policy rendering, exact grant ordering, invalid names
and malformed configuration, persistent root-owned handler placement, binary
stream forwarding, strict target/endpoint failures and nonzero transport exit.
They also reproduce the old Salt handler accepting TCP 10005 and require the
updated handler to refuse it before lookup. These fixtures do not validate a
running production policy configuration or a GUI client.

The installed Qubes policy parser also accepts the full rendered policy and
passes 14 in-memory matching checks: exact grant success, wrong argument,
wrong source, wrong relay, direct RemoteVM destination, and the same requests
with grants removed. The checker calls `find_matching_rule` with fictional VM
metadata; it does not execute a qrexec request or inspect live policy files.

To repeat, render a fixture locally with the test renderer:

```bash
python3 - <<'PY' > /tmp/qubesair-desktop-policy.json
import json
import sys
sys.path.insert(0, 'tests')
from test_desktop_transport import policy
from test_qubesair_rpc import fields
fixtures = {}
for variant, grants in [('granted', [{'source': 'work-client', 'target': 'remote-qa'}]), ('denied', [])]:
    fixtures[variant] = fields(policy(grants)['grpc-csr-policy'], 'file.managed')['contents']
print(json.dumps(fixtures))
PY
```

On a test environment with the Qubes `qrexec.policy` Python package, provide that
fixture to [the memory-only checker](../tests/check_desktop_policy_parser.py):

```bash
python3 tests/check_desktop_policy_parser.py < /tmp/qubesair-desktop-policy.json
```

Validation on 2026-10-24: all 65 deployment tests, all 231 Salt state/top lint
checks, strict YAML lint, changed-handler ShellCheck, top pairing, and the 14
real-parser cases passed. Both handlers match the merged Air source. No
production desktop grant or remote image was deployed during these checks.

## Scoped deployment overlay

The [scoped updater](../scripts/update-qubesair.py) accepts the exact
`mgmt/remotevm/files/qubesair.ConnectDesktop` handler path and
`remotevm.grpc.csr.desktop_grants` in a Qubes Air deployment overlay. It verifies
the handler digest, exact source/target names, at most 32 grants, and membership
in the existing `allowed_callers` before replacing any target file.
The overlay cannot add callers or change general policy actions. Invalid input
must leave every target file unchanged; applying an empty list revokes future
requests when the policy state is reapplied. Existing streams still need separate
closure, and the explicit policy deny must remain installed.

The manifest's `remotevm` patch uses the same configuration shape as above.
Omitting `desktop_grants` preserves existing grants; an explicit `[]` replaces
them with an empty list. If `allowed_callers` is absent, the effective caller is
the configured relay, matching policy rendering. The existing backup and rollback
mechanism covers the handler and configuration together. Applying an overlay
updates Salt sources; apply the relay and policy states to activate the change.

The missing handler path and grant key were reproduced before this update. All
72 deployment tests now pass, including installation, idempotence, explicit
revocation, digest tampering, wildcard/injection/malformed input, caller scope,
size boundaries and rollback after an injected write failure. All 231 Salt
state/top lint checks, strict YAML lint, top pairing and diff checks passed.
These tests use temporary deployment roots and do not mutate production policy.
