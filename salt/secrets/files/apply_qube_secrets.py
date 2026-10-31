#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Chris Su
# SPDX-License-Identifier: MIT
"""Decrypt one qube's sops file and write the files it lists.

Stdout is one JSON object for Salt's stateful cmd.script parser.
Stderr is a short fixed-shape error. File contents are never printed.
"""

from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile

ROOTS = ("/home/user", "/rw")
ALLOWED_MODES = {0o600, 0o640, 0o700, 0o750}


def emit(changed: bool, comment: str) -> None:
    sys.stdout.write(json.dumps({"changed": changed, "comment": comment}) + "\n")


def die(message: str) -> int:
    print(message, file=sys.stderr)
    return 1


def under_root(path: str, roots: tuple[str, ...]) -> str:
    real = os.path.realpath(path)
    for root in roots:
        real_root = os.path.realpath(root)
        if real == real_root or real.startswith(real_root + os.sep):
            return real
    raise ValueError("secrets: refusing path outside home and /rw")


def safe_source(checkout: str, rel: str) -> str:
    if not checkout.startswith("/") or "\x00" in checkout or "\n" in checkout:
        raise ValueError("secrets: checkout must be an absolute path")
    if (
        not rel
        or rel.startswith("/")
        or "\x00" in rel
        or "\n" in rel
        or any(part in ("", ".", "..") for part in rel.split("/"))
    ):
        raise ValueError("secrets: qube file must be a relative path")
    root = os.path.realpath(checkout)
    full = os.path.realpath(os.path.join(root, *rel.split("/")))
    if not full.startswith(root + os.sep):
        raise ValueError("secrets: qube file escapes the checkout")
    return full


def ensure_private_dir(path: str, roots: tuple[str, ...]) -> None:
    if any(part in ("", ".", "..") for part in path.split("/")[1:]):
        raise ValueError("secrets: refusing path")
    if os.path.islink(path):
        raise ValueError("secrets: refusing symlink directory")
    if os.path.isdir(path):
        under_root(path, roots)
        return
    parent = os.path.dirname(path)
    if not parent or parent == path:
        raise ValueError("secrets: refusing path")
    if not os.path.isdir(parent) or os.path.islink(parent):
        ensure_private_dir(parent, roots)
    under_root(parent, roots)
    if os.path.islink(path):
        raise ValueError("secrets: refusing symlink directory")
    os.mkdir(path, 0o700)
    os.chmod(path, 0o700)


def write_files(data: dict, roots: tuple[str, ...] = ROOTS) -> list[str]:
    files = data.get("files")
    if not isinstance(files, list):
        raise ValueError("secrets: decrypted json has no files list")
    changed: list[str] = []
    for item in files:
        if not isinstance(item, dict):
            raise ValueError("secrets: file entry is not an object")
        path = item.get("path")
        content = item.get("content")
        if not isinstance(path, str) or not path.startswith("/"):
            raise ValueError("secrets: file path must be absolute")
        if not os.path.basename(path):
            raise ValueError("secrets: refusing path")
        if any(part in ("", ".", "..") for part in path.split("/")[1:]):
            raise ValueError("secrets: refusing path")
        if not isinstance(content, str):
            raise ValueError("secrets: file content must be text")
        mode_text = item.get("mode", "0600")
        if not isinstance(mode_text, str):
            raise ValueError("secrets: mode must be a 4-digit octal string")
        try:
            mode = int(mode_text, 8)
        except ValueError as exc:
            raise ValueError("secrets: mode is not octal") from exc
        if mode not in ALLOWED_MODES:
            raise ValueError("secrets: refusing mode")
        parent = os.path.dirname(path)
        ensure_private_dir(parent, roots)
        real_parent = under_root(parent, roots)
        final = os.path.join(real_parent, os.path.basename(path))
        if os.path.lexists(final) and not os.path.isfile(final):
            raise ValueError("secrets: refusing to replace a non-file")
        if os.path.islink(final):
            raise ValueError("secrets: refusing to replace a symlink")
        blob = content.encode("utf-8")
        if os.path.isfile(final):
            info = os.lstat(final)
            if stat.S_IMODE(info.st_mode) == mode:
                with open(final, "rb") as handle:
                    if handle.read() == blob:
                        continue
        tmp = final + ".sops-tmp"
        if os.path.lexists(tmp):
            raise ValueError("secrets: temp file already exists")
        fd = os.open(
            tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode
        )
        try:
            os.write(fd, blob)
        finally:
            os.close(fd)
        os.chmod(tmp, mode)
        os.replace(tmp, final)
        changed.append(path)
    return changed


def wipe(path: str) -> None:
    try:
        size = os.path.getsize(path)
        with open(path, "r+b") as handle:
            handle.write(b"\0" * size)
            handle.flush()
            os.fsync(handle.fileno())
    except OSError:
        pass
    try:
        os.remove(path)
    except OSError:
        pass


def decrypt(src: str, dest: str) -> None:
    if shutil.which("sops") is None:
        raise ValueError("secrets: sops is not installed")
    # Drop sops' own stdout. With --output the plaintext stays in dest,
    # and this process never forwards either stream.
    result = subprocess.run(
        ["sops", "-d", "--output-type", "json", "--output", dest, src],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if result.returncode != 0 or not os.path.isfile(dest) or os.path.getsize(dest) == 0:
        raise ValueError("secrets: decrypt failed")


def apply_checkout(
    checkout: str, rel: str, roots: tuple[str, ...] = ROOTS
) -> tuple[bool, str]:
    if os.geteuid() == 0:
        raise ValueError("secrets: refusing to run as root")
    if not os.path.isdir(checkout) or os.path.islink(checkout):
        return False, "secrets: no checkout, skipped"
    src = safe_source(checkout, rel)
    if not os.path.isfile(src) or os.path.islink(src):
        return False, "secrets: no file for this qube, skipped"
    fd, tmp = tempfile.mkstemp(prefix=".sops-", dir=checkout)
    os.close(fd)
    os.chmod(tmp, 0o600)
    try:
        decrypt(src, tmp)
        with open(tmp, "r", encoding="utf-8") as handle:
            data = json.load(handle)
        if not isinstance(data, dict):
            raise ValueError("secrets: decrypted json is not an object")
        changed = write_files(data, roots)
    except json.JSONDecodeError as exc:
        raise ValueError("secrets: decrypted json is invalid") from exc
    finally:
        wipe(tmp)
    if changed:
        return True, "secrets: wrote " + ", ".join(changed)
    return False, "secrets: already applied"


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        return die("secrets: usage: apply_qube_secrets.py CHECKOUT REL")
    try:
        changed, comment = apply_checkout(argv[1], argv[2])
    except (ValueError, OSError) as exc:
        message = str(exc)
        if not message.startswith("secrets:"):
            message = "secrets: apply failed"
        return die(message)
    emit(changed, comment)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
