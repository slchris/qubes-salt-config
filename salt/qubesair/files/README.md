<!--
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT
-->

# `salt/qubesair/files/`

Payloads delivered into the console qube by `qubesair.console`.

## `qubes-air-console` — served from the LAN artifact store

**It no longer belongs in this directory.** The binary is published to the
artifact store alongside the agent `.deb`, terraform and the proxmox provider,
and `cfg.qubesair.console_binary_source` points at that URL. `file.managed`
fetches `http(s)://` sources natively and verifies `source_hash` before
installing, so no state changed. Staging it here still works — point
`console_binary_source` back at the `salt://` URL — but it puts a ~30MB build
artifact in the salt tree that `scripts/setup.sh` copies to dom0 on every
deploy.

Build it from the `qubes-air` repo, then publish:

```sh
# 1. Build. Runs on macOS, produces linux/amd64.
docker run --rm --platform linux/amd64 -v "$PWD":/src -w /src/console/backend \
    golang:1.25 sh -c 'CGO_ENABLED=1 GOOS=linux GOARCH=amd64 go build \
        -trimpath -ldflags="-s -w" -o /src/dist/qubes-air-console ./cmd/server'
shasum -a 256 dist/qubes-air-console

# 2. Publish. Same login + read-back pattern as scripts/publish-agent-deb.sh,
#    same MIRROR_USERNAME / MIRROR_PASSWORD.
```

Then set both keys in the `qubesair` block of `salt/config.jinja`:

```jinja
"console_binary_source": "http://10.31.0.2/local/qubes-air-tools/qubes-air-console",
"console_binary_sha256": "<the digest printed above>",
```

Three parts of that build command are load-bearing:

- **`CGO_ENABLED=1`** — the console uses `mattn/go-sqlite3`, a cgo package.
  `CGO_ENABLED=0` compiles cleanly and produces a binary that fails at runtime
  with `unknown driver "sqlite3"`: a clean build and a console that cannot open
  its own database, so the mistake surfaces only on the target machine.
- **`--platform linux/amd64`** — on an Apple Silicon Mac the `golang` image is
  arm64, and a cgo build targeting `GOARCH=amd64` there needs an x86-64 cross
  toolchain the image does not ship. Running the amd64 image under emulation
  makes the build native inside the container: slower, and correct.
- **`golang:1.25`** — `console/backend/go.mod` requires go >= 1.25.0. This file
  said 1.23, which fails immediately on the toolchain check.

The digest is required either way: `console_binary_sha256` has no default and
the state refuses to render a service around an unpinned binary.

Verify what actually landed in the qube:

```sh
sha256sum /rw/config/qubesair/bin/qubes-air-console
```

## `terraform/` (optional, not provided here)

There is no state that copies the terraform root — see the repo README's
"Enabling orchestration". The old text here described a `terraform_source` key
that was never implemented, which is worse than saying nothing: it reads as a
step already handled. Populate it by hand:

<!-- superseded:
state recurses it into the console's terraform root. Copy the `terraform/`
directory from the `qubes-air` repo if you want the sources managed from here;
-->

Either way `terraform init` must be run once inside the qube — the console goes
straight to plan/apply and never initialises:

```sh
cd /rw/config/qubesair/terraform && HOME=/rw/config/qubesair/home terraform init
```

The preflight refuses to start the console when orchestration is enabled and
`.terraform/` is missing, so a forgotten `init` fails at startup with the command
to run rather than minutes into the first provisioning job.
