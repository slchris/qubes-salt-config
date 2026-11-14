# SPDX-License-Identifier: MIT
"""The RemoteDebug dom0 allow-list must stay scoped to one named qube.

The service is the whitelist channel a LAN-reachable jump qube uses to run a
small set of dom0 commands. qvm-shutdown/qvm-start/qvm-kill are useful for
recovering a wedged qube, but a bare `--all` must never be read as a qube name
(the bug the leading [a-zA-Z0-9] in those rules fixes), and qvm-kill must not
accept `--all` either.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
SERVICE = ROOT / "salt" / "mgmt" / "remote-debug" / "files" / "qubes.RemoteDebug"


def allow_rules():
    text = SERVICE.read_text()
    start = text.index("ALLOW=(") + len("ALLOW=(")
    # The closing paren is alone on its own line; rules themselves contain )
    # inside alternation groups such as (gentoo-|...).
    end = text.index("\n)", start)
    body = text[start:end]
    return re.findall(r"^\s*'(.+)'\s*$", body, re.MULTILINE)


class AllowListTests(unittest.TestCase):
    def setUp(self):
        self.rules = allow_rules()

    def matches(self, cmd):
        return any(re.fullmatch(r, cmd) for r in self.rules)

    def test_named_shutdown_and_kill_allowed(self):
        self.assertTrue(self.matches("qvm-shutdown foo"))
        self.assertTrue(self.matches("qvm-shutdown --wait foo"))
        self.assertTrue(self.matches("qvm-kill sys-gui-vnc"))
        self.assertTrue(self.matches("qvm-start sys-gui-vnc"))

    def test_all_is_never_a_qube_name(self):
        for cmd in ("qvm-shutdown --all", "qvm-kill --all", "qvm-start --all"):
            self.assertFalse(self.matches(cmd), cmd)

    def test_kill_is_single_target_only(self):
        self.assertFalse(self.matches("qvm-kill foo bar"))
        self.assertFalse(self.matches("qvm-kill foo; rm -rf /"))

    def test_force_flag_not_silently_widened(self):
        self.assertFalse(self.matches("qvm-shutdown --force foo"))

    def test_remove_stays_scoped(self):
        # qvm-remove is limited to the gentoo build qubes and the two named
        # qubesair ones; a system qube is never removable over this channel.
        self.assertTrue(self.matches("qvm-remove -f gentoo-dev"))
        self.assertTrue(self.matches("qvm-remove -f qubesair-console"))
        self.assertFalse(self.matches("qvm-remove -f sys-net"))
        self.assertFalse(self.matches("qvm-remove -f sys-mullvad-701"))


if __name__ == "__main__":
    unittest.main()
