# Qubes Air v0.2.1 artifact pins

Fresh guests could not install the v0.2.0 agent from its GitHub release URL:
the generated installer did not follow redirects, and `dpkg -i` could not
resolve dependencies missing from the base image. The
[v0.2.1 release](https://github.com/slchris/qubes-air/releases/tag/v0.2.1)
fixes both paths while keeping TLS and the pinned SHA256 checks. It also
preserves Proxmox request cancellation when response EOF races with cancellation.

All eight configured payloads now use this release's URLs and verified SHA256
values. Signed tag `v0.2.1` points to
`9095f59d3dcb86e183b864dc7d2398c95b8a497d`, containing Air PRs #104 and #105.
The [artifact record](../salt/qubesair/artifacts.json) records that source,
the release workflow, the manifest digest and all deployed payload digests.

## Validation and deployment boundary

Air PR #105 passed 24 checks; all five workflows on the final merged source
passed. Release workflow
[40112383006](https://github.com/slchris/qubes-air/actions/runs/40112383006)
published nine assets. All nine downloaded files match GitHub's digest and size;
the eight payloads also match `SHA256SUMS`. The web archive contains the expected
index and has no absolute paths, parent traversal or special file entries.

In an offline Debian 13 Linux/amd64 container, the downloaded Console, backup
and four transport helpers report `version=v0.2.1`, the exact revision above,
and `tree=clean`. The agent extracted from the published Debian package reports
`qubes-air-agent 0.2.1`. Handler bytes match both this Salt tree and the tagged
Air source. These checks concern the actual published files.

The installer from that exact tag also downloaded the published v0.2.1 Debian
package in a clean Debian 13 amd64 container, verified its digest and installed
the initially absent dependencies through real APT. The agent reports version
0.2.1 and no failure marker or downloaded package remains. Service commands were
stubbed because the container has no systemd PID 1; this does not test bootstrap
or production service readiness.

All 74 deployment contract tests, 231 Salt state/top lint inputs, strict YAML
lint, top pairing, changed documentation links and diff checks passed. No build
output or private deployment configuration is included in this update.

Existing deployments must update the private overlay's pins as well, since the
scoped updater preserves omitted fields. Apply the normal Console and Relay
states, then compare the running Console identity and deployed file hashes.
The v0.2.0 rollout encountered Salt SSH download stalls requiring manual
prefetch; this pin update does not fix or claim to validate download retries.

`desktop_grants` remains empty. Pinning the release does not establish a
production desktop session, a full disaster takeover or provider lifecycle
acceptance; those need their own recorded results. The previous pin and runtime
evidence is retained in [the v0.2.0 record](qubesair-release-v0.2.0.md).
