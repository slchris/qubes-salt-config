#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Chris Su
# SPDX-License-Identifier: MIT

import datetime
import importlib.util
import re
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


agents = load("bump_agents")
templates = load("bump_templates")


class AgentPinTest(unittest.TestCase):
    def test_lock_fields_round_trip(self):
        text = (ROOT / "salt/agents/lock.yml").read_text()
        version = agents.read_field(text, ("agents", "claude-code"), "version")
        sha = agents.read_field(text, ("tools", "sops"), "sha256")
        self.assertRegex(version, r"^\d+\.\d+\.\d+-\d+$")
        self.assertRegex(sha, r"^[0-9a-f]{64}$")
        rewritten = agents.set_block_fields(text, ("tools", "sops"), {"sha256": sha})
        self.assertEqual(rewritten, text)
        sls = (ROOT / "salt/agents/template/tools.sls").read_text()
        self.assertNotIn(sha, sls)
        self.assertIn("sops.sha256", sls)
        self.assertIn("helm.apt_version", sls)

    def test_sibling_block_stays(self):
        text = "agents:\n  codex:\n    version: \"1\"\n  pi:\n    version: \"2\"\n"
        updated = agents.set_block_fields(text, ("agents", "codex"), {"version": "9"})
        self.assertIn("version: \"9\"", updated)
        self.assertIn("version: \"2\"", updated)

    def test_packages_pick_stable_not_a_newer_beta(self):
        text = "\n\n".join([
            "Package: google-chrome-beta\nVersion: 9.0.0-1\nFilename: beta.deb\nSHA256: " + ("b" * 64),
            "Package: google-chrome-stable\nVersion: 2.0.0-1\nFilename: old.deb\nSHA256: " + ("a" * 64),
            "Package: google-chrome-stable\nVersion: 2.1.0-1\nFilename: new.deb\nSHA256: " + ("c" * 64),
        ])
        best = agents.best_package(text, "google-chrome-stable")
        self.assertEqual(best["Version"], "2.1.0-1")
        self.assertEqual(best["Filename"], "new.deb")

    def test_node_sums_keep_the_pinned_major(self):
        text = "\n".join([
            "aa" * 32 + "  node-v24.0.1-linux-x64.tar.xz",
            "bb" * 32 + "  node-v22.1.0-linux-arm64.tar.xz",
            "cc" * 32 + "  node-v22.1.0-linux-x64.tar.xz",
        ])
        self.assertEqual(agents.node_from_sums(text, 22), ("22.1.0", "c" * 64))

    def test_older_or_same_pin_is_left_alone(self):
        self.assertFalse(agents.moved("2.1.309-1", "2.1.292-1", "a" * 64, "b" * 64))
        self.assertFalse(agents.moved("1.0.0", "1.0.0"))
        self.assertTrue(agents.moved("1.0.0", "1.0.0", "a" * 64, "b" * 64))
        self.assertTrue(agents.moved("3.20.2-1", "3.22.0-1"))

    def test_helm_stays_on_major_3(self):
        text = "\n\n".join([
            "Package: helm\nVersion: 4.3.0-1",
            "Package: helm\nVersion: 3.20.2-1",
            "Package: helm\nVersion: 3.22.0-1",
        ])
        self.assertEqual(agents.helm_candidate(text), "3.22.0-1")

    def test_sops_refuses_a_prerelease(self):
        with self.assertRaises(SystemExit):
            agents.sops_release({"tag_name": "v3.14.0", "prerelease": True, "assets": []})


class TemplatePinTest(unittest.TestCase):
    def test_near_eol_picks_the_oldest_published_successor(self):
        today = datetime.date(2026, 11, 1)
        cycles = {
            43: datetime.date(2026, 12, 9),
            44: datetime.date(2027, 6, 2),
            45: datetime.date(2027, 12, 8),
        }
        published = {43, 44}
        self.assertEqual(templates.plan_distro(43, today, cycles, published), 44)

    def test_far_from_eol_stays(self):
        today = datetime.date(2026, 11, 1)
        cycles = {13: datetime.date(2028, 8, 9), 14: datetime.date(2030, 8, 9)}
        self.assertIsNone(templates.plan_distro(13, today, cycles, {13, 14}))

    def test_missing_package_does_not_invent_a_version(self):
        today = datetime.date(2026, 12, 1)
        cycles = {43: datetime.date(2026, 12, 9), 44: datetime.date(2027, 6, 2)}
        self.assertIsNone(templates.plan_distro(43, today, cycles, {43}))

    def test_index_and_rewrite_leave_the_gui_template(self):
        html = "qubes-template-fedora-44-minimal-1.rpm qubes-template-fedora-43-xfce-1.rpm"
        self.assertEqual(templates.published_minimal(html)["fedora"], {44})
        text = "\n".join([
            'qvm_fedora_version = "43"',
            "cfg.qvm.fedora.get('version', '43')",
            '"fedora": {"version": "43"',
            "fedora-43-minimal",
            "fedora-43-xfce",
        ])
        updated = templates.rewrite(text, "fedora", 43, 44)
        self.assertIn('qvm_fedora_version = "44"', updated)
        self.assertIn("fedora-44-minimal", updated)
        self.assertIn("fedora-43-xfce", updated)
        self.assertNotIn("fedora-43-minimal", updated)

    def test_config_renders_the_assignment(self):
        from jinja2 import Environment, FileSystemLoader

        text = (ROOT / "salt/config.jinja").read_text()
        debian = re.search(r'qvm_debian_version = "(\d+)"', text).group(1)
        fedora = re.search(r'qvm_fedora_version = "(\d+)"', text).group(1)
        env = Environment(loader=FileSystemLoader(str(ROOT / "salt")))
        cfg = env.get_template("config.jinja").module.cfg
        self.assertEqual(cfg["qvm"]["debian"]["version"], debian)
        self.assertEqual(cfg["qvm"]["fedora"]["version"], fedora)
        self.assertEqual(cfg["remote_debug"]["template"], "debian-" + debian + "-minimal")
        self.assertEqual(cfg["tailscale"]["template"], "debian-" + debian + "-minimal")
        self.assertEqual(cfg["gui_vnc"]["template"], "fedora-43-xfce")

    def test_apply_updates_a_tree(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config = root / "salt" / "config.jinja"
            jinja = root / "salt" / "fedora" / "template.jinja"
            readme = root / "readme.md"
            config.parent.mkdir(parents=True)
            jinja.parent.mkdir(parents=True)
            config.write_text('qvm_fedora_version = "43"\nfedora-43-xfce\n')
            jinja.write_text("cfg.qvm.fedora.get('version', '43')\n")
            readme.write_text("| fedora-43-minimal |\n")
            templates.apply_versions(root, "fedora", 43, 44)
            self.assertIn('qvm_fedora_version = "44"', config.read_text())
            self.assertIn("fedora-43-xfce", config.read_text())
            self.assertIn("version', '44'", jinja.read_text())
            self.assertIn("fedora-44-minimal", readme.read_text())


if __name__ == "__main__":
    unittest.main()
