#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Chris Su
# SPDX-License-Identifier: MIT
"""Refresh salt/magpie/lock.yml from yetone/magpie-releases.

The login qube does not pick this up by itself. After the pin changes,
copy the file onto each login qube and restart qubes-magpie.service.
"""

import hashlib
import json
import re
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOCK_PATH = ROOT / "salt" / "magpie" / "lock.yml"
README_PATH = ROOT / "salt" / "magpie" / "README.md"
ASSET = "magpie-cli-linux-amd64"
REPO = "yetone/magpie-releases"
TAG_RE = re.compile(r"^v(\d+(?:\.\d+)*)$")
README_VERSION_RE = re.compile(
    r"`magpie-cli-linux-amd64` v\d+(?:\.\d+)*, not the GTK build:"
)
README_FENCE_RE = re.compile(
    r"https://github\.com/yetone/magpie-releases/releases/download/"
    r"v\d+(?:\.\d+)*/magpie-cli-linux-amd64\n[0-9a-f]{64}"
)


def load_lock(text):
    pin = {}
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line or ":" not in line:
            continue
        key, value = line.split(":", 1)
        pin[key.strip()] = value.strip().strip("\"'")
    missing = [key for key in ("repo", "asset", "version", "url", "sha256") if key not in pin]
    if missing:
        raise SystemExit("lock.yml is missing " + ", ".join(missing))
    return pin


def render_lock(pin):
    return (
        "# SPDX-FileCopyrightText: 2026 Chris Su\n"
        "# SPDX-License-Identifier: MIT\n"
        "#\n"
        "# Pinned magpie CLI for the login qube. scripts/bump_magpie.py is the\n"
        "# only writer. It follows the newest non-prerelease tag of\n"
        "# yetone/magpie-releases that publishes magpie-cli-linux-amd64, checks\n"
        "# that file against SHA256SUMS, and opens a pull request. GTK packages\n"
        "# are ignored. Salt does not download this file.\n"
        "\n"
        "repo: {repo}\n"
        "asset: {asset}\n"
        "version: \"{version}\"\n"
        "url: \"{url}\"\n"
        "sha256: \"{sha256}\"\n"
    ).format(**pin)


def version_tuple(version):
    return tuple(int(part) for part in version.split("."))


def digest_from_sums(text, asset):
    found = []
    for raw in text.splitlines():
        parts = raw.split()
        if len(parts) != 2:
            continue
        digest, name = parts
        name = name[1:] if name.startswith("*") else name
        if name != asset and not name.endswith("/" + asset):
            continue
        if re.fullmatch(r"[0-9a-f]{64}", digest) is None:
            raise SystemExit("SHA256SUMS digest for " + asset + " is not 64 hex chars")
        found.append(digest)
    if len(found) != 1:
        raise SystemExit("SHA256SUMS has " + str(len(found)) + " lines for " + asset)
    return found[0]


def update_readme(text, version, url, sha256):
    updated, version_count = README_VERSION_RE.subn(
        "`magpie-cli-linux-amd64` v" + version + ", not the GTK build:",
        text,
        count=1,
    )
    updated, fence_count = README_FENCE_RE.subn(url + "\n" + sha256, updated, count=1)
    if version_count != 1 or fence_count != 1:
        raise SystemExit("README pin block was not found")
    return updated


def release_url(tag):
    return (
        "https://github.com/" + REPO + "/releases/download/"
        + tag + "/" + ASSET
    )


def plan_update(pin, release, sums_text, binary):
    if release.get("draft") or release.get("prerelease"):
        raise SystemExit("refusing a draft or prerelease")
    tag = release.get("tag_name") or ""
    match = TAG_RE.fullmatch(tag)
    if match is None:
        raise SystemExit("release tag is not a plain version: " + tag)
    names = [item.get("name") for item in release.get("assets") or []]
    if ASSET not in names or "SHA256SUMS" not in names:
        raise SystemExit(tag + " does not publish " + ASSET + " and SHA256SUMS")
    version = match.group(1)
    digest = digest_from_sums(sums_text, ASSET)
    actual = hashlib.sha256(binary).hexdigest()
    if actual != digest:
        raise SystemExit("downloaded " + ASSET + " does not match SHA256SUMS")
    proposed = {
        "repo": REPO,
        "asset": ASSET,
        "version": version,
        "url": release_url(tag),
        "sha256": digest,
    }
    if pin.get("repo") != REPO or pin.get("asset") != ASSET:
        raise SystemExit("lock.yml is not the " + REPO + " " + ASSET + " pin")
    same_version = version_tuple(version) == version_tuple(pin["version"])
    if version_tuple(version) < version_tuple(pin["version"]):
        return None
    if same_version and pin["sha256"] == digest and pin["url"] == proposed["url"]:
        return None
    return proposed


def fetch(url, token):
    headers = {
        "User-Agent": "qubes-salt-config-magpie-bump",
        "Accept": "application/vnd.github+json",
    }
    if token:
        headers["Authorization"] = "Bearer " + token
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read()


def pr_body(version):
    return (
        "Upstream `yetone/magpie-releases` published terminal CLI v"
        + version + ".\n\n"
        "This updates `salt/magpie/lock.yml` and the digest in "
        "`salt/magpie/README.md`. The file was checked against that tag's "
        "`SHA256SUMS`. GTK builds are not used.\n\n"
        "Merging does not install the binary. On each login qube, replace "
        "`/rw/config/magpie/bin/magpie` (mode 0755, owner user) and restart "
        "the unit:\n\n"
        "```sh\n"
        "sudo systemctl restart qubes-magpie.service\n"
        "```\n\n"
        "Do not restart the qube. A qube restart drops the Claude login.\n"
    )


def main():
    import os
    if len(sys.argv) > 1 and sys.argv[1] == "--print-version":
        print(load_lock(LOCK_PATH.read_text())["version"])
        return 0
    if len(sys.argv) > 1 and sys.argv[1] == "--pr-body":
        version = load_lock(LOCK_PATH.read_text())["version"]
        Path(sys.argv[2]).write_text(pr_body(version))
        return 0
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    pin = load_lock(LOCK_PATH.read_text())
    payload = fetch("https://api.github.com/repos/" + REPO + "/releases/latest", token)
    release = json.loads(payload.decode())
    tag = release.get("tag_name") or ""
    sums = fetch(release_url(tag).rsplit("/", 1)[0] + "/SHA256SUMS", token)
    binary = fetch(release_url(tag), token)
    proposed = plan_update(pin, release, sums.decode(), binary)
    if proposed is None:
        print("magpie pin is current at v" + pin["version"])
        return 0
    LOCK_PATH.write_text(render_lock(proposed))
    README_PATH.write_text(update_readme(README_PATH.read_text(), proposed["version"], proposed["url"], proposed["sha256"]))
    print("magpie pin updated v" + pin["version"] + " -> v" + proposed["version"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
