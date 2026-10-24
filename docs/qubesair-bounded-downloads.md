# Bounded Qubes Air artifact downloads

The v0.2.0 rollout stalled twice inside Salt SSH's HTTPS streaming download.
The v0.2.1 preview reproduced the problem before changing any running artifact:
the Console download stopped at 14,529,368 bytes while v0.2.0 stayed healthy.
The deployed Salt source uses a one-hour HTTP request default. That explains
the long wait, but the underlying streaming stall has not been diagnosed.

Console, web, backup, issuer, endpoint lister and both Relay helpers now stage
HTTPS payloads through [a confined downloader](../salt/qubesair/files/fetch-artifact.py).
The normal states install from that local cache. Native `salt://` sources keep
their existing source and digest configuration. HTTP artifact URLs are refused;
configure HTTPS or a native Salt source.

## Behavior and trust boundary

The downloader accepts exactly one of seven fixed artifact identifiers. A
root-owned JSON request supplies only the HTTPS URL and SHA256; no destination,
command, CA override or timing settings are accepted from the caller. The cache,
requests and every ancestor must be real root-owned directories not writable by
other users. Symlinks, nonregular files, multiple hard links and unsafe ownership
or permissions fail closed. An exclusive per-artifact lock rejects concurrent
staging.

Each attempt has a 10-second socket timeout and a 120-second total budget. There
are at most two attempts, separated by two seconds; the Salt command also has a
250-second outer budget. Payloads are capped at 128 MiB, redirects at five, and
every request uses HTTPS with the system CA store and hostname verification.
Proxy environment variables are ignored. Downloads therefore require direct
HTTPS connectivity from the target Qube.

A temporary file replaces its cache entry only after a complete body and the
configured SHA256 have been verified. A failed download keeps the previous cache
entry. Normal timeout, failure and SIGTERM/SIGINT paths remove their temporary
file; SIGKILL or host loss can leave a bounded temporary file. A subsequent
successful run never treats that partial file as a verified cache entry.
An unchanged, verified cache is reused without network access. Salt output
reports whether the cache changed, the successful attempt count and byte count;
response bodies and signed redirect URLs are not logged.

The helper does not install active binaries or restart services. The existing
Console candidate database preflight, artifact ownership, service ordering and
release pins still apply. This is not a transaction across every artifact:
failure late in an apply can leave earlier, successfully installed files updated.
Inspect the failed states and running build identity before retrying.

## Deployment and preview

Salt's `test=True` checks a local source even when a prerequisite would create
it. A preview with an empty cache therefore fails with “Local file source … does
not exist”; it does not download the payload. Prepare the cache before previewing:

```sh
sudo qubesctl --skip-dom0 --targets=<console>,<relay> state.apply qubesair.artifact-prefetch
sudo qubesctl --skip-dom0 --targets=<console> state.apply qubesair.console,qubesair.backup,mgmt.remotevm.grpc-console test=True
sudo qubesctl --skip-dom0 --targets=<relay> state.apply mgmt.remotevm.grpc-csr-relay test=True
```

`artifact-prefetch` uses only the enabled roles and exact Qube names in
`config.jinja`; an unrelated target or dom0 is refused. It writes only the
root-owned helper, request files and verified cache under
`/rw/config/qubesair-artifacts`. Review the previews, then apply the same normal
states without `test=True`. A direct normal apply also supports an empty cache;
its prerequisites perform the same bounded staging first.

The scoped updater allows the exact helper state, prefetch state and macro paths.
Deploy those files together with the four changed consumers, then prepare both
Qubes' caches. Do not remove hash verification or substitute locally built files
to make a failed release download appear successful.

## Verification

The original seven HTTPS entry points failed the new staging contract test
before the states changed. Real TLS tests cover successful redirects, transient
failure and retry, stalled and continuously slow bodies, truncated/empty/partial
responses, wrong SHA256, declared and streamed size limits, wrong CA and hostname,
redirect loops and HTTPS downgrade. Filesystem tests cover ownership, unsafe
ancestors, symlinks, hard links, FIFOs, concurrent staging and failed publication.
SIGTERM cleanup also failed before cancellation handling was added.

An offline Linux container ran the unmodified helper at its real root-owned
paths. Successful staging, idempotence, refusal of a non-root caller and request
symlink, and bad-digest preservation passed. With the production defaults, two
stalled attempts failed in 22.15 seconds; the prior cache survived and no partial
file remained.

An offline Salt 3007.1 container verified six cache-preparation states, seven
preview/install states, no network requests during preview, direct installation
from an empty cache, zero changes on repeated apply, and preservation of the
installed file after a failed fetch. The initial empty-cache preview failure is
retained as the reason for the explicit preparation phase. These are isolated
checks; field rollout results must be recorded separately.

Reproduce the contract suite with `python3 -m unittest discover -s tests -v`.
Run `tests/check_artifact_fetch_linux.py` and `tests/check_artifact_fetch_salt.py`
only in fresh root Linux containers without an existing artifact cache. They
create disposable TLS fixtures and the real `/rw/config/qubesair-artifacts`
layout; the Salt check additionally requires Salt and its runtime dependencies.
