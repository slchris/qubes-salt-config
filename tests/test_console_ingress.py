# SPDX-License-Identifier: MIT
"""Exercise the firewall helper's bounded, exact-scope reconciliation."""
import copy
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / 'salt/qubesair/files/console-ingress.py'
SPEC = importlib.util.spec_from_file_location('ingress', SCRIPT)
ingress = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ingress)


def rule(gateway='192.0.2.1', port=8080, handle=9):
    return {'family': 'ip', 'table': 'qubes', 'chain': 'custom-input',
            'handle': handle, 'comment': ingress.TAG,
            'expr': [{'match': {'op': '==', 'left': {'payload': {'protocol': 'ip', 'field': 'saddr'}}, 'right': gateway}},
                     {'match': {'op': '==', 'left': {'payload': {'protocol': 'tcp', 'field': 'dport'}}, 'right': port}},
                     {'match': {'op': '==', 'left': {'ct': {'key': 'state'}}, 'right': {'set': ['established', 'related', 'new']}}},
                     {'accept': None}]}


class Runtime:
    def __init__(self):
        self.name = 'qubesair-console'
        self.gateway = '192.0.2.1'
        self.rules = []
        self.calls = []
        self.failure = None
        self.ignore = False
        self.snapshot = None

    def __call__(self, argv, body=None):
        self.calls.append((argv, body))
        if argv == [ingress.QDB, '/name']:
            return self.name + '\n'
        if argv == [ingress.QDB, '/qubes-gateway']:
            return self.gateway + '\n'
        if argv == [ingress.NFT, '-j', 'list', 'chain', 'ip', 'qubes', 'custom-input']:
            return self.snapshot if self.snapshot is not None else json.dumps({'nftables': [{'rule': r} for r in self.rules]})
        if argv != [ingress.NFT, '-f', '-']:
            raise AssertionError('unexpected command: ' + repr(argv))
        if self.failure:
            raise self.failure
        if self.ignore:
            return ''
        changed = copy.deepcopy(self.rules)
        for line in body.splitlines():
            words = line.split()
            if words[:6] == ['delete', 'rule', 'ip', 'qubes', 'custom-input', 'handle']:
                changed = [r for r in changed if r['handle'] != int(words[6])]
            elif words[:8] == ['add', 'rule', 'ip', 'qubes', 'custom-input', 'ip', 'saddr', self.gateway]:
                changed.append(rule(self.gateway, int(words[10])))
            else:
                raise AssertionError('unexpected transaction: ' + line)
        self.rules = changed
        return ''

    @property
    def writes(self):
        return [body for _, body in self.calls if body is not None]


class IngressTests(unittest.TestCase):
    def setUp(self):
        self.runtime = Runtime()
        self.config = {'enabled': True, 'qube': 'qubesair-console', 'listen': '0.0.0.0:8080'}

    def test_firewall_reset_repeat_and_gateway_change(self):
        self.assertTrue(ingress.apply(self.config, self.runtime))
        self.assertFalse(ingress.apply(self.config, self.runtime))
        self.assertEqual(len(self.runtime.writes), 1)
        self.runtime.rules = []  # Qubes rebuilds its base rules on AppVM boot.
        self.assertTrue(ingress.apply(self.config, self.runtime))
        self.runtime.gateway = '192.0.2.2'
        self.assertTrue(ingress.apply(self.config, self.runtime))
        self.assertEqual(self.runtime.rules, [rule('192.0.2.2')])
        self.assertEqual(len(self.runtime.writes[-1].splitlines()), 2)

    def test_disable_and_duplicate_recovery_preserve_unrelated_rules(self):
        unrelated = rule(port=22, handle=5)
        unrelated['comment'] = 'ssh-managed-elsewhere'
        self.runtime.rules = [unrelated, rule(handle=7), rule(handle=8)]
        self.assertTrue(ingress.apply(self.config, self.runtime))
        self.assertEqual(self.runtime.rules, [unrelated, rule()])
        self.config['enabled'] = False
        self.assertTrue(ingress.apply(self.config, self.runtime))
        self.assertEqual(self.runtime.rules, [unrelated])
        self.assertFalse(ingress.apply(self.config, self.runtime))

    def test_no_default_network_exposure(self):
        self.config.update(enabled=False, listen='127.0.0.1:8080')
        self.assertFalse(ingress.apply(self.config, self.runtime))
        self.assertFalse(self.runtime.writes)
        self.assertNotIn(([ingress.QDB, '/qubes-gateway'], None), self.runtime.calls)

    def test_invalid_config_never_calls_nft(self):
        for patch in ({'enabled': 'yes'}, {'enabled': 1}, {'qube': '@anyvm'},
                      {'qube': 'x;id'}, {'listen': '0.0.0.0:8080;id'},
                      {'listen': '0.0.0.0:0'}, {'listen': '0.0.0.0:65536'},
                      {'listen': '0.0.0.0:22'}, {'listen': '127.0.0.1:8080'},
                      {'listen': '[::]:8080'}, {'listen': '224.0.0.1:8080'},
                      {'extra': '/etc/passwd'}):
            with self.subTest(patch=patch):
                runtime = Runtime()
                with self.assertRaises(ValueError):
                    ingress.apply({**self.config, **patch}, runtime)
                self.assertFalse(runtime.calls)

    def test_wrong_qube_and_bad_gateway_fail_before_any_mutation(self):
        for name, gateway in [('other-qube', '192.0.2.1'), ('qubesair-console', ''),
                              ('qubesair-console', '::1'), ('qubesair-console', '127.0.0.1'),
                              ('qubesair-console', '192.0.2.1\nadd rule'),
                              ('qubesair-console', '0.0.0.0'), ('qubesair-console', '224.0.0.1'),
                              ('qubesair-console', '255.255.255.255')]:
            with self.subTest(name=name, gateway=gateway):
                runtime = Runtime(); runtime.name = name; runtime.gateway = gateway
                with self.assertRaises(ValueError):
                    ingress.apply(self.config, runtime)
                self.assertFalse(runtime.writes)

    def test_read_write_timeout_and_failed_verification_propagate(self):
        self.runtime.snapshot = 'incomplete'
        with self.assertRaises(ValueError):
            ingress.apply(self.config, self.runtime)
        self.assertFalse(self.runtime.writes)
        for failure in (subprocess.CalledProcessError(1, 'nft'), subprocess.TimeoutExpired('nft', 10)):
            runtime = Runtime(); runtime.failure = failure
            with self.assertRaises(subprocess.SubprocessError):
                ingress.apply(self.config, runtime)
            self.assertEqual(runtime.rules, [])
        runtime = Runtime(); runtime.ignore = True
        with self.assertRaisesRegex(ValueError, 'verification'):
            ingress.apply(self.config, runtime)

    def test_malformed_owned_rule_and_excess_refused(self):
        for rules in ([{**rule(), 'handle': '9;id'}], [{**rule(), 'chain': 'forward'}],
                      [rule(handle=n) for n in range(1, 10)]):
            with self.subTest(rules=rules):
                runtime = Runtime(); runtime.rules = rules
                with self.assertRaises(ValueError):
                    ingress.apply(self.config, runtime)
                self.assertFalse(runtime.writes)

    def test_drift_with_same_marker_is_repaired(self):
        drift = rule(); drift['expr'][0]['match']['right'] = '0.0.0.0/0'
        self.runtime.rules = [drift]
        self.assertTrue(ingress.apply(self.config, self.runtime))
        self.assertEqual(self.runtime.rules, [rule()])

    def test_native_state_bitmask_and_explicit_set_are_both_exact(self):
        # nft 1.1.3 on the actual host emits `in` + array for a bitmask and
        # `==` + {set: ...} for the helper's explicit set syntax.
        mask = rule()
        mask['expr'][2]['match'].update(op='in', right=['new', 'related', 'established'])
        for existing in (rule(), mask):
            runtime = Runtime(); runtime.rules = [existing]
            self.assertFalse(ingress.apply(self.config, runtime))
            self.assertFalse(runtime.writes)
        for right in ({'set': ['new', 'established']}, {'set': ['new', 'related', 1]},
                      {'set': ['new', 'related', 'established'], 'extra': True}):
            altered = rule(); altered['expr'][2]['match']['right'] = right
            self.assertFalse(ingress.matches(altered, '192.0.2.1', 8080))

    def test_lock_serializes_reloads_and_is_reusable_after_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'lock'
            first = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
            second = os.open(path, os.O_RDWR)
            try:
                ingress.acquire_lock(first)
                inode = path.stat().st_ino
                with mock.patch.object(ingress.time, 'monotonic', side_effect=[0, 11]):
                    with self.assertRaises(TimeoutError):
                        ingress.acquire_lock(second)
                fcntl.flock(first, fcntl.LOCK_UN)
                ingress.acquire_lock(second)
                self.assertEqual(path.stat().st_ino, inode)
            finally:
                os.close(first); os.close(second)

    def test_root_files_refuse_symlinks_and_writable_configuration(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(ingress, 'ROOT', Path(directory)):
            target = Path(directory) / 'actual'
            target.write_text('{}')
            link = Path(directory) / 'config.json'
            link.symlink_to(target)
            with self.assertRaises(OSError):
                ingress.root_file('config.json', os.O_RDONLY)
            link.unlink(); link.write_text('{}'); link.chmod(0o666)
            with self.assertRaises(ValueError):
                ingress.root_file('config.json', os.O_RDONLY)

    def test_cli_rejects_arguments_without_running_commands(self):
        with mock.patch.object(ingress.sys, 'argv', ['apply.py', '--arbitrary']), mock.patch.object(ingress, 'run') as run:
            with self.assertRaises(ValueError):
                ingress.main()
            run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
