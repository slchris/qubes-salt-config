# Qubes Air v0.2.2 artifact pins

The [v0.2.2 release](https://github.com/slchris/qubes-air/releases/tag/v0.2.2)
checks the identity of unencrypted data mounts before probing or formatting a
disk and before starting the agent. Missing, foreign, read-only, stacked and
nested mounts fail closed. A correct existing ext4 mount is reused. This is Air
PR #106 (DATA-02); its isolated QEMU, package and regression evidence is recorded
in the [Air review](https://github.com/slchris/qubes-air/blob/v0.2.2/docs/reviews/2026-10-25-plain-data-mount-identity.md).

All eight configured payloads now use the published URLs and verified SHA256
values. Signed tag `v0.2.2` points to
`85aff42b110d3911699c5a5472e3ba7b61863ec9`. The
[artifact record](../salt/qubesair/artifacts.json) binds those payloads, the
manifest and the three transport handlers to that source and release workflow.
The handlers' bytes have not changed since v0.2.1.

## Verification

Air PR #107 passed all 24 checks, and all five workflows on the final merged
source passed. Release workflow
[40123911570](https://github.com/slchris/qubes-air/actions/runs/40123911570)
published nine assets. All nine downloaded files match GitHub's digest and size;
the eight payloads also match `SHA256SUMS`. The web archive contains its expected
index and has no absolute paths, parent traversal, links or special file entries.

In an offline, read-only Debian 13 Linux/amd64 container, the downloaded Console,
backup and four helpers report `version=v0.2.2`, the exact revision above and
`tree=clean`. Their build metadata reports Go 1.26.10. The extracted agent reports
version 0.2.2 and the Debian package identifies amd64; its shared data-mount
checker matches the tagged source byte for byte. Handler bytes match both this
Salt tree and the Air tag. These checks concern the actual published files.

All 93 deployment contract tests, 235 Salt state/top lint inputs, strict YAML
lint, top pairing, changed documentation links and diff checks passed. The TLS
tests require local loopback listeners; the sandbox-denied first run was retained
and the same suite passed with listener access.

## Deployment boundary

Existing deployments must update their private overlay's pins as well. Use the
[bounded prefetch, preview and apply sequence](qubesair-bounded-downloads.md),
then compare the running Console identity and installed artifact hashes.
Preserve existing service grants and gateway ingress configuration during the
artifact update. `desktop_grants` remains empty in the repository defaults.

The Console embeds the new cloud-init checker and agent startup dependency.
Updating Console and its agent package pin does not replace cloud-init or update
agents in existing guests. Unencrypted provider lifecycle acceptance needs a
newly generated guest configuration; encrypted bootstrap retains its own path.
Artifact publication and isolated verification do not establish that lifecycle,
a production desktop session or a complete disaster takeover.

The prior release and installer evidence remains in the
[v0.2.1 record](qubesair-release-v0.2.1.md).
