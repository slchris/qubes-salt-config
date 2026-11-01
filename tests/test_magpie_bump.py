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


class MagpieBumpTest(unittest.TestCase):
    def test_lock_matches_readme(self):
        pin = bump.load_lock((ROOT / "salt/magpie/lock.yml").read_text())
        readme = (ROOT / "salt/magpie/README.md").read_text()
        self.assertEqual(pin["version"], "0.1.2344")
        self.assertIn("v" + pin["version"], readme)
        self.assertIn(pin["url"], readme)
        self.assertIn(pin["sha256"], readme)
        self.assertEqual(bump.render_lock(pin), (ROOT / "salt/magpie/lock.yml").read_text())

    def test_sums_line_ignores_gtk_package(self):
        digest = "a" * 64
        text = "b" * 64 + "  magpie-linux-amd64\n" + digest + " *magpie-cli-linux-amd64\n"
        self.assertEqual(bump.digest_from_sums(text, bump.ASSET), digest)

    def test_newer_release_replaces_pin(self):
        pin = bump.load_lock((ROOT / "salt/magpie/lock.yml").read_text())
        digest = "c" * 64
        binary = b"magpie-bytes"
        proposed = bump.plan_update(pin, release(), sums_for(hashlib.sha256(binary).hexdigest()), binary)
        self.assertEqual(proposed["version"], "0.1.2350")
        self.assertTrue(proposed["url"].endswith("/v0.1.2350/magpie-cli-linux-amd64"))
        readme = bump.update_readme(
            (ROOT / "salt/magpie/README.md").read_text(),
            proposed["version"],
            proposed["url"],
            proposed["sha256"],
        )
        self.assertIn("v0.1.2350", readme)
        self.assertNotIn("v0.1.2344", readme)
        self.assertIn(proposed["sha256"], readme)

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
