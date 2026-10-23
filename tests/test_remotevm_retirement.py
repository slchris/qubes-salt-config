# SPDX-License-Identifier: MIT
"""The dom0 retirement boundary must never remove an ordinary VM or hide partial cleanup."""
from pathlib import Path
import json
import os
import subprocess
import tempfile
import unittest

import jinja2

ROOT = Path(__file__).resolve().parents[1]
FAKE = '''#!/usr/bin/env python3
from pathlib import Path
import json, os, sys
cmd = Path(sys.argv[0]).name
with open(os.environ['QA_CALLS'], 'a') as out:
    out.write(json.dumps([cmd] + sys.argv[1:]) + '\\n')
if cmd == os.environ.get('QA_FAIL'):
    sys.exit(1)
state = Path(os.environ['QA_STATE'])
vm = json.loads(state.read_text())
if cmd == 'qvm-ls':
    if vm:
        print('remote-alpha|' + vm['class'])
elif cmd == 'qvm-prefs':
    print(vm.get(sys.argv[-1], ''))
elif cmd == 'qvm-tags':
    if sys.argv[1:] != ['--', 'remote-alpha', 'list', 'remote-zone']:
        sys.exit(2)
    sys.exit(0 if vm.get('managed') else 1)
elif cmd == 'qvm-remove':
    state.write_text('{}')
elif cmd == 'qvm-run':
    name = sys.stdin.read().strip()
    print(os.environ.get('QA_REPLY', 'OK ' + name))
else:
    sys.exit(2)
'''


class RetirementTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        source = (ROOT / 'salt/mgmt/remotevm/files/qubesair.RegisterRemoteVM').read_text()
        self.script = self.root / 'register'
        self.script.write_text(jinja2.Environment(undefined=jinja2.StrictUndefined).from_string(source).render(
            relay='relay', transport='qubesair.GrpcProxy', cleanup_endpoints=True))
        self.state = self.root / 'vm.json'
        self.vm = {'class': 'RemoteVM', 'remote_name': 'alpha', 'relayvm': 'relay',
                   'transport_rpc': 'qubesair.GrpcProxy', 'managed': True}
        self.state.write_text(json.dumps(self.vm))
        self.calls = self.root / 'calls'
        self.calls.touch()
        for command in ('qvm-ls', 'qvm-prefs', 'qvm-tags', 'qvm-remove', 'qvm-run'):
            path = self.root / command
            path.write_text(FAKE)
            path.chmod(0o755)
        # macOS does not ship GNU timeout; the handler's own execution is bounded
        # by subprocess.run below. Production uses coreutils on Qubes dom0.
        timeout = self.root / 'timeout'
        timeout.write_text('#!/bin/sh\nshift\nexec "$@"\n')
        timeout.chmod(0o755)
        self.env = {**os.environ, 'PATH': str(self.root) + ':' + os.environ['PATH'],
                    'QA_STATE': str(self.state), 'QA_CALLS': str(self.calls)}

    def call(self, request='deregister remote-alpha\n', **env):
        return subprocess.run(['bash', str(self.script)], input=request, text=True,
                              capture_output=True, env={**self.env, **env}, timeout=5)

    def test_owned_remote_and_already_absent_are_idempotent(self):
        result = self.call()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, 'OK RETIRED remote-alpha relay=verified\n')
        self.assertEqual(json.loads(self.state.read_text()), {})
        self.assertEqual(self.call().returncode, 0)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertEqual(sum(c[0] == 'qvm-remove' for c in calls), 1)
        syncs = [c for c in calls if c[0] == 'qvm-run']
        self.assertEqual(len(syncs), 2, 'retry must still clean Relay after the shell is gone')
        self.assertIn('--service', syncs[0])
        self.assertEqual(syncs[0][-2:], ['relay', 'qubesair.ForgetEndpoint'])

    def test_wrong_class_or_binding_never_reaches_delete(self):
        for field, value in [('class', 'AppVM'), ('remote_name', 'beta'), ('relayvm', 'other'),
                             ('transport_rpc', 'other.Service'), ('managed', False)]:
            with self.subTest(field=field):
                self.state.write_text(json.dumps({**self.vm, field: value}))
                self.calls.write_text('')
                self.assertNotEqual(self.call().returncode, 0)
                self.assertNotIn('qvm-remove', self.calls.read_text())
                self.assertNotIn('qvm-run', self.calls.read_text())

    def test_partial_cleanup_failure_requires_retry(self):
        result = self.call(QA_FAIL='qvm-run')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('FAILED', result.stdout)
        self.assertEqual(json.loads(self.state.read_text()), {})
        self.assertEqual(self.call().returncode, 0)

    def test_inventory_and_remove_failures_never_claim_success(self):
        for command in ('qvm-ls', 'qvm-remove'):
            with self.subTest(command=command):
                self.assertNotEqual(self.call(QA_FAIL=command).returncode, 0)
                self.assertEqual(json.loads(self.state.read_text()), self.vm)

    def test_malformed_ack_is_failure_even_with_zero_exit(self):
        for reply in ('', 'OK remote-beta', 'OK remote-alpha extra', 'x' * 10000):
            self.assertNotEqual(self.call(QA_REPLY=reply).returncode, 0)

    def test_service_argument_is_rejected_before_inventory(self):
        result = subprocess.run(['bash', str(self.script), 'unexpected'],
                                input='deregister remote-alpha\n', text=True,
                                capture_output=True, env=self.env, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls.read_text(), '')

    def test_request_grammar_is_bounded_and_exact(self):
        for request in ('', 'deregister remote-alpha', 'deregister remote-alpha extra\n',
                        'deregister remote-alpha\nsecond\n', 'deregister ordinary\n',
                        'deregister remote-../alpha\n', 'deregister remote-' + 'a' * 25 + '\n',
                        'deregister ' + 'x' * 300 + '\n'):
            with self.subTest(length=len(request)):
                self.calls.write_text('')
                self.assertNotEqual(self.call(request).returncode, 0)
                self.assertEqual(self.calls.read_text(), '')


if __name__ == '__main__':
    unittest.main()
