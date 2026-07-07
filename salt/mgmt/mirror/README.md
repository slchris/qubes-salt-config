# mgmt.mirror

Point Qubes at a download mirror via Salt — the deployable counterpart to
`scripts/qubes-mirror.sh`. Configured by the `qvm:mirror` pillar block, off by
default. See also [docs/mirror.md](../../../docs/mirror.md).

## Why this exists

`scripts/qubes-mirror.sh` must be run by hand; the mirror URLs in pillar do
nothing on their own. This formula applies them with `state.apply`, like every
other part of the project, so a redeploy re-applies the mirror automatically.

## What it does

| State | Runs in | Layer | File(s) |
|-------|---------|-------|---------|
| `dom0` | dom0 | 1 + 3 | `/etc/qubes/repo-templates/*.repo`, `/etc/yum.repos.d/qubes-dom0.repo` |
| `debian` | Debian template | 2 | `/etc/apt/sources.list*` |
| `fedora` | Fedora template | 2 | `/etc/yum.repos.d/fedora*.repo` |

Layer 1 = template downloads (`qvm-template` / `*.clone` states) — the one that
stalls when the ITL source is slow. Layer 2 = in-template `apt`/`dnf`. Layer 3 =
dom0 updates. Each change backs the original up to `*.qbak`.

## Configure

Edit `qvm:mirror` in `pillar/user.sls`:

```yaml
qvm:
  mirror:
    enabled: true      # <-- must be true or every state is a no-op
    templates_baseurl: "https://mirrors.tuna.tsinghua.edu.cn/qubesos/repo/yum"
    debian_baseurl:    "https://mirrors.tuna.tsinghua.edu.cn/debian"
    fedora_baseurl:    "https://mirrors.tuna.tsinghua.edu.cn/fedora/linux"
    dom0_baseurl:      "https://mirrors.tuna.tsinghua.edu.cn/qubesos/repo/yum"
```

Blank a URL to skip that layer. `enabled: false` makes every state a no-op.

## Apply

```sh
# Layer 1 + 3 (dom0)
sudo qubesctl state.apply mgmt.mirror.dom0

# Layer 2 (per template — target each one you use)
sudo qubesctl --skip-dom0 --targets=debian-13-minimal state.apply mgmt.mirror.debian
sudo qubesctl --skip-dom0 --targets=fedora-43-minimal state.apply mgmt.mirror.fedora
```

## Verify

```sh
# Layer 1 (dom0):
grep -H baseurl /etc/qubes/repo-templates/*.repo        # expect the mirror host

# Layer 2 (in a template):
qvm-run --pass-io debian-13-minimal 'grep -rh mirror /etc/apt/sources.list*'
qvm-run --pass-io -u root debian-13-minimal 'time apt-get update'   # should be fast
```

## Revert

Restore the `*.qbak` backups the states created:

```sh
# dom0 (layer 1 + 3):
sudo sh -c 'for f in /etc/qubes/repo-templates/*.repo.qbak; do mv -f "$f" "${f%.qbak}"; done'
sudo sh -c '[ -f /etc/yum.repos.d/qubes-dom0.repo.qbak ] && mv -f /etc/yum.repos.d/qubes-dom0.repo.qbak /etc/yum.repos.d/qubes-dom0.repo'

# In a template (layer 2), e.g. Debian:
qvm-run --pass-io -u root debian-13-minimal \
  'for f in /etc/apt/sources.list.qbak /etc/apt/sources.list.d/*.qbak; do [ -f "$f" ] && mv -f "$f" "${f%.qbak}"; done; apt-get update'
```
