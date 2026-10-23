<!-- SPDX-License-Identifier: MIT -->
# Qubes Air deployment payloads

Console, Web and backup payloads may be staged here for a scoped deployment
bundle or fetched from an artifact URL. Salt verifies every configured SHA256.
Generated binaries and archives are ignored by Git; commit their provenance in
[artifacts.json](../artifacts.json), and keep environment-specific sources in the
local deployment manifest described in the [deployment guide](../README.md).

Build Console and backup with the reviewed qubes-air source on linux/amd64 and
the Go version declared by that source's `console/backend/go.mod`:

```sh
CGO_ENABLED=1 VERSION=<reviewed-version> scripts/build-release-binary.sh ./cmd/server dist/qubes-air-console
CGO_ENABLED=1 VERSION=<reviewed-version> scripts/build-release-binary.sh ./cmd/qubes-air-backup dist/qubes-air-backup
sha256sum dist/qubes-air-console dist/qubes-air-backup
```

Both programs use SQLite through cgo. Their release script verifies the embedded
version/revision/build time. The candidate Console must support `--check-database`;
this runs before replacing active files, and refuses unreadable or newer schemas.
An old binary that lacks this flag cannot be deployed over an existing database.

Build Web with the repository's frontend check/build procedure and package its
`dist/` contents. Build the agent package with `scripts/build-agent-deb.sh`, publish
it at a URL reachable by guests, and verify its read-back digest before applying
the Console state. The agent URL has no environment-specific default.

Build the four qrexec helpers from that same source and record each digest:

```sh
cd console/backend
for helper in issue-relay-cert list-endpoints relay-call relay-bootstrap; do
    CGO_ENABLED=1 GOOS=linux GOARCH=amd64 go build -trimpath -o "../../dist/$helper" "./cmd/$helper"
done
```

Use a native Linux build environment with the matching Go toolchain and C
compiler. `artifacts.json` groups artifacts by the source revision that built them;
`go version -m` independently reports their VCS revision and clean source tree.
An upgrade that retains unchanged Web, agent, backup or Relay binaries keeps their
original build record. The Console revision does not describe those retained files.
The current Console and endpoint lister use `06cfff3`, which includes version-1
endpoint snapshots and verified retirement; their pins must be upgraded together
with the Relay and dom0 states described in the deployment checklist.
