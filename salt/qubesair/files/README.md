<!--
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT
-->

# `salt/qubesair/files/`

Payloads delivered into the console qube by `qubesair.console`.

## `qubes-air-console` (not committed)

The console binary. There is no CI publishing it, so it is cross-compiled by
hand and dropped here; `.gitignore` excludes it because it is a ~30MB build
artifact rather than source.

Build it from the `qubes-air` repo:

```sh
cd console/backend
CGO_ENABLED=1 GOOS=linux GOARCH=amd64 go build \
    -trimpath -ldflags='-s -w' \
    -o /path/to/qubes-salt-config/salt/qubesair/files/qubes-air-console \
    ./cmd/server
sha256sum /path/to/qubes-salt-config/salt/qubesair/files/qubes-air-console
```

`CGO_ENABLED=1` is not optional. The console uses `mattn/go-sqlite3`, which is a
cgo package: building with `CGO_ENABLED=0` succeeds and produces a binary that
fails at runtime with `unknown driver "sqlite3"`. That is a clean compile and a
console that cannot open its own database, so the mistake surfaces only on the
target machine. Cross-compiling from macOS therefore needs a linux/amd64
toolchain — the least painful route is a container:

```sh
docker run --rm -v "$PWD":/src -w /src/console/backend golang:1.23 \
    sh -c 'CGO_ENABLED=1 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o /src/qubes-air-console ./cmd/server'
```

Put the resulting digest in `cfg.qubesair.console_binary_sha256`. The state
refuses to deploy without it: an unpinned hand-built binary has nothing
distinguishing the reviewed build from whatever is at that path, and salt
verifies `source_hash` before installing.

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
