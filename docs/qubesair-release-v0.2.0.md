# Qubes Air v0.2.0 artifact pins

The default configuration now fetches all eight Qubes Air payloads from the
[v0.2.0 release](https://github.com/slchris/qubes-air/releases/tag/v0.2.0), with
explicit SHA256 pins. The source is signed tag `v0.2.0` at
`232b280cc395fe64cb48e2e3206ad776256d404e`.
This replaces the locally staged QA binaries and the empty agent package URL.
The [artifact record](../salt/qubesair/artifacts.json) records the publication,
manifest digest, source revision and every deployed payload digest.

This phase's acceptance criteria are: all configured URLs belong to this exact
release; all downloaded bytes match both `SHA256SUMS` and GitHub asset metadata;
the Linux binaries report the expected source/version; the Debian package
reports version `0.2.0`; deployment contracts and repository lint pass; desktop
grants stay empty. A missing URL or digest still refuses Console deployment.

## Version and deployment scope

Console, backup and the four transport helpers report `version=v0.2.0` and the
source revision above. The Debian package and agent report `0.2.0`, as produced
by the existing package-version normalization. The web bundle is from the same
release. The fixed qrexec handlers' recorded hashes match both this Salt tree
and that Air revision, including the refusal of retired TCP port 10005.

New installations use the public release URLs directly. An existing deployment
must update its private overlay's pins too: the scoped updater preserves fields
that are omitted. Review the overlay, apply the Console/Relay states through the
existing Salt entry points, then compare runtime identity and installed file
digests. The release's transport files are individually pinned under
`remotevm.grpc.csr`; installing a new Console binary does not update them.

Desktop remains opt-in. Empty `desktop_grants` denies new desktop calls, and the
agent package does not install Xpra, create the desktop account or enable the
desktop unit. Remote image preparation and actual Qubes window/persistence tests
remain separate requirements in [the desktop guide](qubesair-desktop.md).

## Download and runtime evidence

Release workflow
[40098108139](https://github.com/slchris/qubes-air/actions/runs/40098108139)
completed successfully on 2026-10-24 and published nine files: eight payloads
plus `SHA256SUMS`. All eight payloads passed manifest verification, and all nine
files matched the digest and size returned by GitHub. The web archive contained
the expected index and only relative paths without parent traversal.

In an offline Debian 13 Linux/amd64 container, the downloaded Console, backup
and four helpers each reported the exact release revision and `tree=clean`.
The agent extracted from the downloaded `.deb` reported `qubes-air-agent 0.2.0`.
These are checks of published bytes, not a production rollout or a provider
lifecycle acceptance result.

All 74 deployment tests passed after the pin update, including positive default
URL rendering, missing-URL refusal, release URL/manifest consistency and current
handler provenance. All 231 Salt state/top lint checks, strict YAML lint, top
pairing and diff checks passed. No local build output is committed.
