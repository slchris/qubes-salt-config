# Qubes Air v0.2.3 artifact pins

The [v0.2.3 release](https://github.com/slchris/qubes-air/releases/tag/v0.2.3)
validates the fixed scsi1, mapper and mount identity before legacy data-key
migration. RekeyData now validates complete JSON fields and distinguishes a
rejected passphrase from probe execution failures. Failed or empty privileged
runner responses leave completion unconfirmed, preserving the stored DEK and
migration marker for retry. The implementation and isolated Linux evidence are
in [Air PR #108](https://github.com/slchris/qubes-air/pull/108) and its
[review](https://github.com/slchris/qubes-air/blob/v0.2.3/docs/reviews/2026-10-25-rekey-data-validation.md).

All eight configured payloads use published URLs and verified SHA256 values.
Signed tag `v0.2.3` points to
`0fc61e9ad4730206cdd8d3601bdfb81443b935a3`. The
[artifact record](../salt/qubesair/artifacts.json) binds those payloads, the
checksum manifest and three transport handlers to that source and workflow.
The handlers' bytes are unchanged from v0.2.2.

## Verification

Air PR #108 passed all 24 checks and the merged source passed all five main
workflows. Release workflow
[40128827573](https://github.com/slchris/qubes-air/actions/runs/40128827573)
published nine assets. Each downloaded file matches GitHub's digest and size;
all eight payloads also match `SHA256SUMS`. The web archive contains its index
and no absolute paths, parent traversal, links or special file entries.

In an offline Debian 13 Linux/amd64 container, the downloaded Console, backup
and four helpers report `version=v0.2.3`, that exact revision and `tree=clean`.
Their Go build metadata reports Go 1.26.10. The extracted agent reports 0.2.3
and the Debian package identifies amd64. Both RekeyData and the shared mount
checker match tagged source byte for byte. The first container check stopped
because its temporary filesystem was not executable; the final check used an
explicitly executable tmpfs, retaining a read-only root and no network.

All 93 Salt deployment contract tests, 235 state/top lint inputs, strict YAML,
top pairing, changed documentation links and diff checks passed. Publication
of these pins does not establish production acceptance.

## Deployment boundary

Update the private overlay with the same pins, following the
[bounded prefetch, preview and apply sequence](qubesair-bounded-downloads.md).
Preserve existing service grants and gateway ingress configuration, then verify
running identities and installed hashes. Repository `desktop_grants` remains
empty; this update adds no network exposure or service grant.

Updating Console and its package pin does not upgrade existing guests. The
guest must receive RekeyData and its checker together from the agent package.
Production migration still requires an identified legacy disk, its original
master, explicit target confirmation, file/keyslot verification and the Console
migration-marker and provider lifecycle checks. Never create a replacement
master or discard a marker because a probe failed. Isolated LUKS/systemd tests
do not establish that production migration, a desktop session or a complete
disaster takeover.

Previous release evidence remains in the [v0.2.2 record](qubesair-release-v0.2.2.md).
