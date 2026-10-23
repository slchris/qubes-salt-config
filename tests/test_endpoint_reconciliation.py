# SPDX-License-Identifier: MIT
"""Complete snapshots, narrow cleanup and serialized timer/purge reconciliation."""
from pathlib import Path
import fcntl
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import jinja2

ROOT = Path(__file__).resolve().parents[1]


def snapshot(records=''):
    data = records.encode('ascii')
    return (b'QUBES-AIR-ENDPOINTS 1\n' + data +
            f'END {records.count(chr(10))} {hashlib.sha256(data).hexdigest()}\n'.encode('ascii'))


FAKE = '''#!/usr/bin/env python3
from pathlib import Path
import json, os, sys, time
cmd = Path(sys.argv[0]).name
with open(os.environ['QA_LOG'], 'a') as log:
    log.write(json.dumps([cmd] + sys.argv[1:]) + '\\n')
if os.environ.get('QA_FAIL') == cmd:
    sys.exit(1)
if cmd == 'qrexec-client-vm':
    data = Path(os.environ['QA_SNAPSHOT']).read_bytes()
    if os.environ.get('QA_GATE'):
        Path(os.environ['QA_FETCHED']).touch()
        while not Path(os.environ['QA_GATE']).exists():
            time.sleep(0.01)
    sys.stdout.buffer.write(data)
    sys.exit(0)
path = Path(os.environ['QA_DB'])
db = json.loads(path.read_text())
if cmd == 'qubesdb-list':
    args = sys.argv[1:]
    full_path = args[0] == '-f'
    prefix = args[1] if full_path else args[0]
    # QubesDB CLI strips the requested prefix unless -f is supplied.
    print(''.join((key if full_path else key[len(prefix):]) + '\\n'
                  for key in sorted(db) if key.startswith(prefix)), end='')
elif cmd == 'qubesdb-write':
    db[sys.argv[1]] = sys.argv[2]
elif cmd == 'qubesdb-rm':
    if not os.environ.get('QA_SKIP_REMOVE'):
        db.pop(sys.argv[1], None)
else:
    sys.exit(2)
path.write_text(json.dumps(db))
'''


class EndpointTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        source = (ROOT / 'salt/mgmt/remotevm/files/refresh-endpoints.py.jinja').read_text()
        rendered = jinja2.Environment(undefined=jinja2.StrictUndefined).from_string(source).render(
            console='console', runtime_dir=str(self.root))
        self.script = self.root / 'refresh-endpoints.py'
        self.script.write_text(rendered)
        self.rpc = self.root / 'qubesair.ForgetEndpoint'
        self.rpc.write_text(rendered)
        self.lock = self.root / 'endpoints.lock'
        self.lock.touch()
        self.db = self.root / 'db.json'
        self.db.write_text(json.dumps({'/remote-endpoint/remote-gone': '192.0.2.9:8443',
                                      '/remote-endpoint/manual': 'keep',
                                      '/remote-endpoint/remote-gone/nested': 'keep',
                                      '/unrelated/key': 'keep'}))
        self.payload = self.root / 'snapshot'
        self.payload.write_bytes(snapshot('alpha 192.0.2.1:8443\n'))
        self.log = self.root / 'calls'
        self.log.touch()
        for name in ('qrexec-client-vm', 'qubesdb-list', 'qubesdb-write', 'qubesdb-rm'):
            executable = self.root / name
            executable.write_text(FAKE)
            executable.chmod(0o755)
        self.env = {**os.environ, 'PATH': str(self.root) + ':' + os.environ['PATH'],
                    'QA_DB': str(self.db), 'QA_SNAPSHOT': str(self.payload),
                    'QA_LOG': str(self.log), 'QREXEC_REMOTE_DOMAIN': 'dom0'}
        spec = importlib.util.spec_from_file_location('endpoint_refresh', self.script)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)

    def call(self, data=None, **env):
        path = self.script if data is None else self.rpc
        return subprocess.run([sys.executable, str(path)], input=data, capture_output=True,
                              env={**self.env, **env}, timeout=8)

    def test_refresh_reaps_retired_entries_and_preserves_other_namespaces(self):
        result = self.call()
        self.assertEqual(result.returncode, 0, result.stderr)
        db = json.loads(self.db.read_text())
        self.assertNotIn('/remote-endpoint/remote-gone', db)
        self.assertEqual(db['/remote-endpoint/remote-alpha'], '192.0.2.1:8443')
        for key in ('/unrelated/key', '/remote-endpoint/manual', '/remote-endpoint/remote-gone/nested'):
            self.assertEqual(db[key], 'keep')
        self.assertEqual(self.call(b'remote-gone\n').stdout, b'OK remote-gone\n')
        self.assertEqual(self.call(b'remote-gone\n').returncode, 0)

    def test_complete_empty_snapshot_removes_last_endpoint(self):
        self.payload.write_bytes(snapshot())
        self.assertEqual(self.call().returncode, 0)
        self.assertNotIn('/remote-endpoint/remote-gone', json.loads(self.db.read_text()))

    def test_bad_snapshot_or_fetch_changes_nothing(self):
        valid = snapshot('alpha 192.0.2.1:8443\n')
        invalid = [b'', valid[:-1], valid[:-15], valid + b'garbage\n',
                   valid.replace(b'END 1 ', b'END 0 '), valid.replace(b'192.0.2.1', b'192.0.2.2'),
                   snapshot('alpha 192.0.2.1:8443\nalpha 192.0.2.2:8443\n'),
                   snapshot('bad/name 192.0.2.1:8443\n'), snapshot('alpha 999.0.0.1:8443\n'),
                   snapshot('alpha 192.0.2.1:0\n'), snapshot('alpha 192.0.2.1:65536\n'),
                   snapshot('alpha 192.0.2.1:8443 extra\n'), b'x' * (1024 * 1024 + 1)]
        before = self.db.read_bytes()
        for data in invalid:
            with self.subTest(length=len(data)):
                self.payload.write_bytes(data)
                self.assertNotEqual(self.call().returncode, 0)
                self.assertEqual(self.db.read_bytes(), before)
        self.payload.write_bytes(valid)
        self.assertNotEqual(self.call(QA_FAIL='qrexec-client-vm').returncode, 0)
        self.assertEqual(self.db.read_bytes(), before)

    def test_explicit_cleanup_refuses_live_target_and_untrusted_caller(self):
        before = self.db.read_bytes()
        self.assertNotEqual(self.call(b'remote-alpha\n').returncode, 0)
        for data in (b'', b'remote-gone', b'remote-gone\nextra\n', b'../gone\n',
                     b'remote-gone extra\n', b'x' * 129):
            self.assertNotEqual(self.call(data).returncode, 0)
        self.assertNotEqual(self.call(b'remote-gone\n', QREXEC_REMOTE_DOMAIN='work').returncode, 0)
        self.assertEqual(self.db.read_bytes(), before)

    def test_partial_failure_is_reported_and_retry_repairs_it(self):
        self.assertNotEqual(self.call(QA_FAIL='qubesdb-rm').returncode, 0)
        self.assertIn('/remote-endpoint/remote-gone', json.loads(self.db.read_text()))
        self.assertEqual(self.call(b'remote-gone\n').returncode, 0)
        self.assertNotIn('/remote-endpoint/remote-gone', json.loads(self.db.read_text()))

    def test_failed_inventory_or_write_cannot_confirm_retirement(self):
        before = self.db.read_bytes()
        for command in ('qubesdb-list', 'qubesdb-write'):
            with self.subTest(command=command):
                result = self.call(b'remote-gone\n', QA_FAIL=command)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b'')
                self.assertEqual(self.db.read_bytes(), before)

    def test_successful_noop_removal_is_not_a_cleanup_confirmation(self):
        result = self.call(b'remote-gone\n', QA_SKIP_REMOVE='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b'')
        self.assertIn('/remote-endpoint/remote-gone', json.loads(self.db.read_text()))
        self.assertEqual(self.call(b'remote-gone\n').stdout, b'OK remote-gone\n')

    def test_command_timeout_and_output_limit(self):
        with patch.dict(os.environ, {**self.env, 'QA_GATE': str(self.root / 'never'),
                                     'QA_FETCHED': str(self.root / 'fetched')}):
            with self.assertRaises(TimeoutError):
                self.module.command(['qrexec-client-vm'], time.monotonic() + 0.3)
        with patch.dict(os.environ, self.env):
            with self.assertRaises(ValueError):
                self.module.command(['qrexec-client-vm'], time.monotonic() + 2, limit=16)
        self.assertEqual(self.call().returncode, 0, 'timeout must release process and lock')

    def test_more_than_one_page_and_entry_limit(self):
        data = ''.join(f'q{i:04d} 192.0.2.1:8443\n' for i in range(105))
        self.assertEqual(len(self.module.parse_snapshot(snapshot(data))), 105)
        too_many = ''.join(f'q{i:05d} 192.0.2.1:8443\n' for i in range(10001))
        with self.assertRaises(ValueError):
            self.module.parse_snapshot(snapshot(too_many))

    def test_lock_timeout_and_restart(self):
        with self.lock.open('r+') as held, patch.dict(os.environ, self.env):
            fcntl.flock(held, fcntl.LOCK_EX)
            with self.assertRaises(TimeoutError):
                self.module.reconcile(None, time.monotonic() + 0.1)
            self.assertEqual(self.log.read_text(), '', 'fetch must happen after lock acquisition')
        self.assertEqual(self.call().returncode, 0)

    def test_slow_old_timer_cannot_reintroduce_a_purged_endpoint(self):
        self.payload.write_bytes(snapshot('gone 192.0.2.9:8443\n'))
        gate, fetched = self.root / 'gate', self.root / 'fetched'
        timer = subprocess.Popen([sys.executable, str(self.script)], stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, env={**self.env, 'QA_GATE': str(gate),
                                                              'QA_FETCHED': str(fetched)})
        try:
            deadline = time.monotonic() + 5
            while not fetched.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(fetched.exists())
            self.payload.write_bytes(snapshot())
            purge = subprocess.Popen([sys.executable, str(self.rpc)], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.env)
            try:
                purge.stdin.write(b'remote-gone\n')
                purge.stdin.close()
                purge.stdin = None
                time.sleep(0.1)
                self.assertIsNone(purge.poll(), 'purge must wait for the timer lock')
                gate.touch()
                timer.communicate(timeout=5)
                out, error = purge.communicate(timeout=5)
                self.assertEqual(purge.returncode, 0, error)
                self.assertEqual(out, b'OK remote-gone\n')
                self.assertNotIn('/remote-endpoint/remote-gone', json.loads(self.db.read_text()))
            finally:
                if purge.poll() is None:
                    purge.kill()
                    purge.communicate()
        finally:
            gate.touch()
            if timer.poll() is None:
                timer.kill()
                timer.communicate()


if __name__ == '__main__':
    unittest.main()
