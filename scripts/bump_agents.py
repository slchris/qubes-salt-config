#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Chris Su
# SPDX-License-Identifier: MIT
"""Refresh salt/agents/lock.yml from upstream releases.

Node stays on the major version already pinned. Helm stays on 3.x.
gh, kubectl, kustomize, and age are Debian packages and are not pinned.
Merging the pull request does not install anything.
"""

import hashlib
import json
import os
import re
import sys
import urllib.request
from pathlib import Path
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[1]
LOCK_PATH = ROOT / "salt" / "agents" / "lock.yml"
SOPS_REPO = "getsops/sops"
HELM_PACKAGES = (
    "https://packages.buildkite.com/helm-linux/helm-debian/any/"
    "dists/any/main/binary-amd64/Packages"
)
DEBS = (
    {
        "name": "claude-code",
        "headings": ("agents", "claude-code"),
        "package": "claude-code",
        "packages_url": (
            "https://downloads.claude.ai/claude-code/apt/stable/"
            "dists/stable/main/binary-amd64/Packages"
        ),
        "base_url": "https://downloads.claude.ai/claude-code/apt/stable/",
    },
    {
        "name": "claude-desktop",
        "headings": ("gui_apps", "claude-desktop"),
        "package": "claude-desktop",
        "packages_url": (
            "https://downloads.claude.ai/claude-desktop/apt/stable/"
            "dists/stable/main/binary-amd64/Packages"
        ),
        "base_url": "https://downloads.claude.ai/claude-desktop/apt/stable/",
    },
    {
        "name": "google-chrome",
        "headings": ("gui_apps", "google-chrome"),
        "package": "google-chrome-stable",
        "packages_url": "https://dl.google.com/linux/chrome/deb/dists/stable/main/binary-amd64/Packages",
        "base_url": "https://dl.google.com/linux/chrome/deb/",
    },
    {
        "name": "vscode",
        "headings": ("gui_apps", "vscode"),
        "package": "code",
        "packages_url": "https://packages.microsoft.com/repos/code/dists/stable/main/binary-amd64/Packages",
        "base_url": "https://packages.microsoft.com/repos/code/",
    },
)
NPMS = (
    ("codex", ("agents", "codex"), "@openai/codex"),
    ("opencode", ("agents", "opencode"), "@opencode/cli"),
    ("pi", ("agents", "pi"), "@earendil-works/pi-coding-agent"),
    ("grok", ("agents", "grok"), "@xai-official/grok"),
)


def version_key(version):
    version = str(version).split(":", 1)[-1]
    upstream, revision = version.rsplit("-", 1) if "-" in version else (version, "0")

    def parts(text):
        found = []
        for piece in re.findall(r"\d+|[A-Za-z]+", text):
            found.append((0, int(piece)) if piece.isdigit() else (1, piece))
        return tuple(found)

    return (parts(upstream), parts(revision))


def unquote(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def _walk(lines, headings):
    idx = 0
    indent = 0
    for heading in headings:
        found = None
        for i in range(idx, len(lines)):
            raw = lines[i]
            if not raw.strip() or raw.lstrip().startswith("#"):
                continue
            current = len(raw) - len(raw.lstrip(" "))
            key = raw.split(":", 1)[0].strip()
            if current == indent and key == heading:
                found = i
                break
            if current < indent:
                break
        if found is None:
            raise SystemExit("lock.yml is missing " + ".".join(headings))
        idx = found + 1
        indent += 2
    end = idx
    while end < len(lines):
        raw = lines[end]
        if raw.strip() and not raw.lstrip().startswith("#"):
            current = len(raw) - len(raw.lstrip(" "))
            if current < indent:
                break
        end += 1
    return idx, end, indent


def read_field(text, headings, field):
    lines = text.splitlines(keepends=True)
    start, end, indent = _walk(lines, headings)
    for i in range(start, end):
        raw = lines[i]
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if len(raw) - len(raw.lstrip(" ")) != indent:
            continue
        key, sep, value = raw.strip().partition(":")
        if sep and key == field:
            return unquote(value)
    raise SystemExit("lock.yml is missing " + ".".join(headings) + "." + field)


def set_block_fields(text, headings, fields):
    lines = text.splitlines(keepends=True)
    start, end, indent = _walk(lines, headings)
    wanted = dict(fields)
    for i in range(start, end):
        raw = lines[i]
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if len(raw) - len(raw.lstrip(" ")) != indent:
            continue
        key = raw.split(":", 1)[0].strip()
        if key not in wanted:
            continue
        newline = " " * indent + key + ': "' + wanted.pop(key) + '"'
        if raw.endswith("\r\n"):
            newline += "\r\n"
        elif raw.endswith("\n"):
            newline += "\n"
        lines[i] = newline
    if wanted:
        missing = ".".join(headings) + "." + ",".join(sorted(wanted))
        raise SystemExit("lock.yml is missing " + missing)
    return "".join(lines)


def moved(old_version, new_version, old_sha=None, new_sha=None):
    if version_key(new_version) < version_key(old_version):
        return False
    if new_version == old_version and (old_sha is None or new_sha == old_sha):
        return False
    return True


def parse_packages(text):
    blocks = []
    for chunk in re.split(r"\n\s*\n", text.strip()):
        item = {}
        folded = []
        for line in chunk.splitlines():
            if line.startswith((" ", "\t")) and folded:
                folded[-1] += " " + line.strip()
            else:
                folded.append(line)
        for line in folded:
            if ":" not in line:
                continue
            key, value = line.split(":", 1)
            item[key.strip()] = value.strip()
        if item.get("Package"):
            blocks.append(item)
    return blocks


def best_package(text, name):
    best = None
    for item in parse_packages(text):
        if item.get("Package") != name or "Version" not in item:
            continue
        if best is None or version_key(item["Version"]) > version_key(best["Version"]):
            best = item
    if best is None:
        raise SystemExit("Packages has no " + name)
    if not best.get("SHA256") or not best.get("Filename"):
        raise SystemExit(name + " " + best.get("Version", "") + " has no SHA256 or Filename")
    if not re.fullmatch(r"[0-9a-f]{64}", best["SHA256"]):
        raise SystemExit(name + " SHA256 is not 64 hex chars")
    return best


def node_from_sums(text, major):
    prefix = "node-v" + str(major) + "."
    suffix = "-linux-x64.tar.xz"
    found = []
    for raw in text.splitlines():
        parts = raw.split()
        if len(parts) != 2:
            continue
        digest, name = parts
        if not name.startswith(prefix) or not name.endswith(suffix):
            continue
        version = name[len("node-v"):-len(suffix)]
        if not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise SystemExit("Node digest is not 64 hex chars")
        found.append((version, digest))
    if len(found) != 1:
        raise SystemExit("Node SHASUMS256 has " + str(len(found)) + " linux-x64 tarballs")
    return found[0]


def helm_candidate(text, major="3"):
    best = None
    for item in parse_packages(text):
        if item.get("Package") != "helm" or "Version" not in item:
            continue
        upstream = item["Version"].split(":", 1)[-1].rsplit("-", 1)[0]
        if upstream.split(".", 1)[0] != major:
            continue
        if best is None or version_key(item["Version"]) > version_key(best):
            best = item["Version"]
    if best is None:
        raise SystemExit("Helm apt repo has no " + major + ".x package")
    return best


def digest_from_checksums(text, filename):
    found = []
    for raw in text.splitlines():
        parts = raw.split()
        if len(parts) != 2:
            continue
        digest, name = parts
        if name.startswith("*"):
            name = name[1:]
        if name == filename or name.endswith("/" + filename):
            found.append(digest)
    if len(found) != 1 or not re.fullmatch(r"[0-9a-f]{64}", found[0] if found else ""):
        raise SystemExit("sops checksums has " + str(len(found)) + " lines for " + filename)
    return found[0]


def sops_release(payload):
    if payload.get("draft") or payload.get("prerelease"):
        raise SystemExit("refusing a draft or prerelease sops release")
    tag = payload.get("tag_name") or ""
    match = re.fullmatch(r"v(\d+(?:\.\d+)*)$", tag)
    if match is None:
        raise SystemExit("sops tag is not a plain version: " + tag)
    version = match.group(1)
    binary = "sops-v" + version + ".linux.amd64"
    sums = "sops-v" + version + ".checksums.txt"
    assets = {item.get("name"): item.get("browser_download_url") for item in payload.get("assets") or []}
    if not assets.get(binary) or not assets.get(sums):
        raise SystemExit(tag + " does not publish " + binary)
    return version, assets[binary], assets[sums]


def fetch(url, token=None):
    headers = {"User-Agent": "qubes-salt-config-pin-bump"}
    if token and "api.github.com" in url:
        headers["Accept"] = "application/vnd.github+json"
        headers["Authorization"] = "Bearer " + token
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=300) as response:
        return response.read()


def sha256_of(url):
    headers = {"User-Agent": "qubes-salt-config-pin-bump"}
    request = urllib.request.Request(url, headers=headers)
    hasher = hashlib.sha256()
    with urllib.request.urlopen(request, timeout=300) as response:
        while True:
            chunk = response.read(1024 * 1024)
            if not chunk:
                break
            hasher.update(chunk)
    return hasher.hexdigest()


def pr_body(changes):
    lines = ["Pinned CLIs that moved:", ""]
    for change in changes:
        lines.append("- " + change["name"] + " " + change["old"] + " -> " + change["new"])
    lines.extend([
        "",
        "Debs, the Node tarball, and sops were downloaded and checked against "
        "the published digest. npm versions are the registry `latest` dist-tag. "
        "Helm stays on major 3. Node stays on its current major. "
        "gh, kubectl, kustomize, and age stay on the Debian template.",
        "",
        "Merging does not install anything. After merging, rebuild and deliver "
        "the bundle, then apply the tool state. Shut `tpl-agents` down. Each "
        "AppVM keeps its old root until that AppVM is restarted.",
        "",
        "```sh",
        "sudo qubesctl --skip-dom0 --targets=agent-build state.apply agents.build.configure",
        "sudo qubesctl state.apply agents.build.run",
        "sudo qubesctl state.apply agents.deliver",
        "sudo qubesctl --skip-dom0 --targets=tpl-agents state.apply agents.template.tools,agents.template.verify",
        "qvm-shutdown --wait tpl-agents",
        "```",
        "",
    ])
    return "\n".join(lines)


def collect(text, token):
    changes = []
    updates = []

    def add(name, headings, old, new, fields):
        changes.append({"name": name, "old": old, "new": new})
        updates.append((headings, fields))

    node_version = read_field(text, ("node",), "version")
    node_sha = read_field(text, ("node",), "sha256")
    major = node_version.split(".", 1)[0]
    sums = fetch("https://nodejs.org/dist/latest-v" + major + ".x/SHASUMS256.txt", token).decode()
    new_version, new_sha = node_from_sums(sums, major)
    if moved(node_version, new_version, node_sha, new_sha):
        url = "https://nodejs.org/dist/v" + new_version + "/node-v" + new_version + "-linux-x64.tar.xz"
        add("node", ("node",), node_version, new_version, {
            "version": new_version,
            "url": url,
            "sha256": new_sha,
            "_url": url,
            "_sha": new_sha,
        })

    for spec in DEBS:
        old_version = read_field(text, spec["headings"], "version")
        old_sha = read_field(text, spec["headings"], "sha256")
        best = best_package(fetch(spec["packages_url"], token).decode(), spec["package"])
        url = spec["base_url"] + best["Filename"]
        if moved(old_version, best["Version"], old_sha, best["SHA256"]):
            add(spec["name"], spec["headings"], old_version, best["Version"], {
                "version": best["Version"],
                "url": url,
                "sha256": best["SHA256"],
                "_url": url,
                "_sha": best["SHA256"],
            })

    for name, headings, package in NPMS:
        old_version = read_field(text, headings, "version")
        payload = json.loads(fetch(
            "https://registry.npmjs.org/" + quote(package, safe="") + "/latest",
            token,
        ).decode())
        new_version = str(payload.get("version") or "")
        if not re.fullmatch(r"\d+(?:\.\d+)+", new_version):
            raise SystemExit(package + " latest is not a plain version: " + new_version)
        if moved(old_version, new_version):
            add(name, headings, old_version, new_version, {"version": new_version})

    helm_old = read_field(text, ("tools", "helm"), "apt_version")
    helm_new = helm_candidate(fetch(HELM_PACKAGES, token).decode())
    if moved(helm_old, helm_new):
        upstream = helm_new.split(":", 1)[-1].rsplit("-", 1)[0]
        add("helm", ("tools", "helm"), helm_old, helm_new, {
            "version": upstream,
            "apt_version": helm_new,
        })

    sops_old = read_field(text, ("tools", "sops"), "version")
    sops_sha = read_field(text, ("tools", "sops"), "sha256")
    payload = json.loads(fetch(
        "https://api.github.com/repos/" + SOPS_REPO + "/releases/latest",
        token,
    ).decode())
    sops_version, binary_url, sums_url = sops_release(payload)
    filename = "sops-v" + sops_version + ".linux.amd64"
    new_sha = digest_from_checksums(fetch(sums_url, token).decode(), filename)
    if moved(sops_old, sops_version, sops_sha, new_sha):
        add("sops", ("tools", "sops"), sops_old, sops_version, {
            "version": sops_version,
            "url": binary_url,
            "sha256": new_sha,
            "_url": binary_url,
            "_sha": new_sha,
        })

    for headings, fields in updates:
        url = fields.get("_url")
        expected = fields.get("_sha")
        if url is None:
            continue
        actual = sha256_of(url)
        if actual != expected:
            raise SystemExit(url + " does not match the published digest")
    cleaned = []
    for headings, fields in updates:
        cleaned.append((headings, {key: value for key, value in fields.items() if not key.startswith("_")}))
    return changes, cleaned


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    summary = None
    if argv[:1] == ["--summary"]:
        if len(argv) != 2:
            raise SystemExit("usage: bump_agents.py --summary PATH")
        summary = Path(argv[1])
    elif argv:
        raise SystemExit("usage: bump_agents.py [--summary PATH]")
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    text = LOCK_PATH.read_text()
    changes, updates = collect(text, token)
    if summary is not None:
        summary.write_text(pr_body(changes) if changes else "pin is current\n")
    if not changes:
        print("agent pins are current")
        return 0
    for headings, fields in updates:
        text = set_block_fields(text, headings, fields)
    LOCK_PATH.write_text(text)
    print("agent pins updated: " + ", ".join(item["name"] + " " + item["old"] + " -> " + item["new"] for item in changes))
    return 0


if __name__ == "__main__":
    sys.exit(main())
