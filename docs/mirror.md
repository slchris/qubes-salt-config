# Qubes Mirrors (Optional)

If template downloads or updates are slow or stall (common far from the ITL CDN,
or when the UpdateVM routes over Tor), you can point Qubes at a faster mirror.
This is **opt-in** and **off by default** — the official sources stay in use
unless you deliberately switch.

> **Symptom this solves:** `sudo qubesctl state.apply debian-minimal.clone`
> hangs for a long time. That state runs `qvm.template_installed`, i.e. it
> **downloads** `debian-13-minimal` from the ITL template repo — it is not a
> local clone. If the repo is unreachable/slow, it appears to hang.

## Table of Contents

*   [Important: signatures still apply](#important-signatures-still-apply)
*   [The three layers](#the-three-layers)
*   [Quick unblock (do this now)](#quick-unblock-do-this-now)
*   [Repeatable setup (pillar + script)](#repeatable-setup-pillar--script)
*   [Reverting](#reverting)
*   [Picking a mirror](#picking-a-mirror)

## Important: signatures still apply

A mirror only changes **where** packages are fetched from, not **whether** they
are verified. Qubes/dnf/apt still check GPG signatures against keys you already
trust, so a mirror serving tampered packages is rejected. Because of that:

*   Only use a mirror you reasonably trust (a well-known university/OS mirror).
*   Do **not** disable `gpgcheck`. If a mirror requires that, do not use it.
*   Mirrors can be stale; if a signature/metadata error appears, the mirror may
    be behind — revert (see [Reverting](#reverting)) and try another.

## The three layers

"Enable a mirror" is not one switch — there are three independent layers, each
in a different place:

| # | Layer | What it feeds | Where it lives |
|---|-------|---------------|----------------|
| 1 | **Template download** | `qvm-template`, `qubes-dom0-update qubes-template-*` (your `*.clone` states) | **dom0** `/etc/qubes/repo-templates/*.repo` |
| 2 | **In-template packages** | `apt`/`dnf` inside a template (your `*.install` states) | **inside each template** `/etc/apt/sources.list*`, `/etc/yum.repos.d/*` |
| 3 | **dom0 updates** | `qubes-dom0-update` (Qubes' own packages) | **dom0** `/etc/yum.repos.d/qubes-dom0.repo` |

Layer 1 is the one that unblocks your stuck template download. Layer 2 speeds up
installing packages in templates. Layer 3 is optional and higher-risk.

## Quick unblock (do this now)

Your `debian-minimal.clone` is stuck because the template can't download. Fix it
directly in **dom0** without Salt:

```sh
# 1. Stop the stuck qubesctl (Ctrl-C in its terminal).

# 2. Point the template repo at a mirror (Tsinghua TUNA — fast from China).
#    This backs up the originals to *.qbak automatically.
sudo ~/QubesIncoming/<qube>/qubes-salt-config/scripts/qubes-mirror.sh \
    --templates-url https://mirrors.tuna.tsinghua.edu.cn/qubesos/repo/yum

# 3. Download the template directly (you now see real progress / errors).
sudo qubes-dom0-update --clean qubes-template-debian-13-minimal
#    or: qvm-template install debian-13-minimal

# 4. Once it succeeds, continue with the normal states.
sudo qubesctl state.apply debian-minimal.create
```

If you don't have the repo checked out in dom0 yet, the same effect by hand:

```sh
sudo sed -i.qbak -E \
  's#https?://[^ ]*yum.qubes-os.org#https://mirrors.tuna.tsinghua.edu.cn/qubesos/repo/yum#g' \
  /etc/qubes/repo-templates/*.repo
sudo sed -i -E 's/^(\s*)(metalink|mirrorlist)\s*=/\1#\2=/' /etc/qubes/repo-templates/*.repo
```

## Repeatable setup (pillar + script)

To make the choice explicit and repeatable, record it in pillar and apply it
with the script.

1. Edit `pillar/user.sls` → `qvm:mirror:` (see the block there):

    ```yaml
    qvm:
      mirror:
        enabled: true
        templates_baseurl: "https://mirrors.tuna.tsinghua.edu.cn/qubesos/repo/yum"
        debian_baseurl:    "https://mirrors.tuna.tsinghua.edu.cn/debian"
        fedora_baseurl:    "https://mirrors.tuna.tsinghua.edu.cn/fedora/linux"
        dom0_baseurl:      "https://mirrors.tuna.tsinghua.edu.cn/qubesos/repo/yum"
    ```

    (Pillar keeps the record; the script below is what actually writes the repo
    files. Blank URLs are left untouched.)

2. Apply in **dom0** with the script. It changes only the layers you pass a URL
   for, backs up originals to `*.qbak`, and supports `--dry-run`:

    ```sh
    cd ~/QubesIncoming/<qube>/qubes-salt-config

    # Layer 1 (template download) + layer 3 (dom0):
    sudo ./scripts/qubes-mirror.sh \
        --templates-url https://mirrors.tuna.tsinghua.edu.cn/qubesos/repo/yum

    # Preview without writing:
    sudo ./scripts/qubes-mirror.sh --dry-run \
        --templates-url https://mirrors.tuna.tsinghua.edu.cn/qubesos/repo/yum
    ```

3. Layer 2 (in-template `apt`/`dnf`) **cannot** be set from dom0. Passing
   `--debian-url`/`--fedora-url` makes the script **print** the exact commands to
   run inside the template qube:

    ```sh
    sudo ./scripts/qubes-mirror.sh \
        --debian-url https://mirrors.tuna.tsinghua.edu.cn/debian
    # -> prints the sed/apt commands to run inside debian-13-minimal
    ```

   Run those inside the template (`qvm-run -u root <template> ...` or a terminal
   in the template), then shut the template down.

## Reverting

Every change is backed up to `<file>.qbak`. Restore all originals:

```sh
sudo ./scripts/qubes-mirror.sh --disable
```

For an in-template change you made by hand, restore its `.qbak` inside that
template (e.g. `sudo mv /etc/apt/sources.list.qbak /etc/apt/sources.list`).

## Picking a mirror

The default in `pillar/user.sls` is **Tsinghua TUNA**
(`mirrors.tuna.tsinghua.edu.cn/qubesos/repo/yum`), verified to carry the Qubes
**r4.3** repos and fast from mainland China. Note the mirror's path segment is
`qubesos` (no hyphen), not `qubes`.

> **Outside China?** `mirrors.kernel.org/qubes/repo/yum` (kernel.org global edge
> CDN, also verified for r4.3) is usually a better default — swap the URLs in
> pillar. Other verified mirrors: `ftp.icm.edu.pl/pub/Linux/dist/qubes/repo/yum`,
> `mirrors.dotsrc.org/qubes/repo/yum`.

For **layer 2** (in-template packages), any domestic Debian/Fedora mirror works
since those distros are widely mirrored (TUNA has both). Layer 1/3 need a mirror
that specifically carries the **Qubes** repos.

When choosing any mirror, check that:

*   It carries the Qubes template repo for **layer 1** — test with
    `curl -I <baseurl>/r4.3/templates-itl/repodata/repomd.xml` (expect `200`
    or a `301`/`302` redirect to a `200`).
*   It carries Debian and/or Fedora for **layer 2**, at a path layout your
    `sources.list` / `.repo` baseurl expects.
*   It is reasonably fresh (mirrors that lag cause signature/metadata errors).

Always keep `gpgcheck` on — see
[Important: signatures still apply](#important-signatures-still-apply).
