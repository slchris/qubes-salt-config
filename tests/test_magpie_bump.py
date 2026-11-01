#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Chris Su
# SPDX-License-Identifier: MIT

import hashlib
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load_script():
    spec = importlib.util.spec_from_file_location(
        "bump_magpie", ROOT / "scripts" / "bump_magpie.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


bump = load_script()


def release(tag="v0.1.2350", draft=False, prerelease=False):
    return {
        "tag_name": tag,
        "draft": draft,
        "prerelease": prerelease,
        "assets": [{"name": "magpie-cli-linux-amd64"}, {"name": "SHA256SUMS"}],
    }


def sums_for(digest):
    return digest + "  magpie-cli-linux-amd64\n" + ("ab" * 32) + "  magpie-linux-amd64\n"


def next_version(version):
    parts = [int(part) for part in version.split(".")]
    parts[-1] += 1
    return ".".join(str(part) for part in parts)


class MagpieBumpTest(unittest.TestCase):
    def test_lock_matches_readme(self):
        lock_text = (ROOT / "salt/magpie/lock.yml").read_text()
        pin = bump.load_lock(lock_text)
        readme = (ROOT / "salt/magpie/README.md").read_text()
        sentence = "`magpie-cli-linux-amd64` v" + pin["version"] + ", not the GTK build:"
        self.assertRegex(pin["version"], r"^[0-9]+\.[0-9]+\.[0-9]+$")
        self.assertIn(sentence, readme)
        self.assertIn(pin["url"], readme)
        self.assertIn(pin["sha256"], readme)
        self.assertEqual(bump.render_lock(pin), lock_text)

    def test_sums_line_ignores_gtk_package(self):
        digest = "a" * 64
        text = "b" * 64 + "  magpie-linux-amd64\n" + digest + " *magpie-cli-linux-amd64\n"
        self.assertEqual(bump.digest_from_sums(text, bump.ASSET), digest)

    def test_newer_release_replaces_pin(self):
        pin = bump.load_lock((ROOT / "salt/magpie/lock.yml").read_text())
        version = next_version(pin["version"])
        tag = "v" + version
        binary = b"magpie-bytes"
        proposed = bump.plan_update(
            pin, release(tag=tag), sums_for(hashlib.sha256(binary).hexdigest()), binary
        )
        self.assertEqual(proposed["version"], version)
        self.assertTrue(proposed["url"].endswith("/" + tag + "/magpie-cli-linux-amd64"))
        readme = bump.update_readme(
            (ROOT / "salt/magpie/README.md").read_text(),
            proposed["version"],
            proposed["url"],
            proposed["sha256"],
        )
        old_sentence = "`magpie-cli-linux-amd64` v" + pin["version"] + ", not the GTK build:"
        new_sentence = "`magpie-cli-linux-amd64` v" + version + ", not the GTK build:"
        self.assertIn(new_sentence, readme)
        self.assertNotIn(old_sentence, readme)
        self.assertIn(proposed["sha256"], readme)
        self.assertNotIn(pin["sha256"], readme)

    def test_same_pin_is_left_alone(self):
        pin = bump.load_lock((ROOT / "salt/magpie/lock.yml").read_text())
        binary = b"current"
        digest = hashlib.sha256(binary).hexdigest()
        pin = dict(pin, sha256=digest, url=bump.release_url("v" + pin["version"]))
        proposed = bump.plan_update(
            pin,
            release(tag="v" + pin["version"]),
            sums_for(digest),
            binary,
        )
        self.assertIsNone(proposed)

    def test_older_upstream_does_not_downgrade(self):
        pin = bump.load_lock((ROOT / "salt/magpie/lock.yml").read_text())
        binary = b"old"
        proposed = bump.plan_update(
            pin,
            release(tag="v0.1.1"),
            sums_for(hashlib.sha256(binary).hexdigest()),
            binary,
        )
        self.assertIsNone(proposed)

    def test_hash_mismatch_refuses_the_pin(self):
        pin = bump.load_lock((ROOT / "salt/magpie/lock.yml").read_text())
        with self.assertRaises(SystemExit):
            bump.plan_update(pin, release(), sums_for("d" * 64), b"not-that-file")

    def test_prerelease_is_refused(self):
        pin = bump.load_lock((ROOT / "salt/magpie/lock.yml").read_text())
        binary = b"rc"
        with self.assertRaises(SystemExit):
            bump.plan_update(
                pin,
                release(prerelease=True),
                sums_for(hashlib.sha256(binary).hexdigest()),
                binary,
            )


if __name__ == "__main__":
    unittest.main()
