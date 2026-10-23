# SPDX-License-Identifier: MIT
"""Regression checks for the deployed qrexec boundary and durable helpers."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

import jinja2
import yaml

ROOT = Path(__file__).resolve().parents[1]


def render(name, csr):
    env = jinja2.Environment(loader=jinja2.ChoiceLoader([
        jinja2.DictLoader({'config.jinja': '{% set cfg = supplied %}'}),
        jinja2.FileSystemLoader(ROOT / 'salt'),
    ]), undefined=jinja2.StrictUndefined)
    return yaml.safe_load(env.get_template('mgmt/remotevm/' + name + '.sls').render(
        supplied={'remotevm': {'grpc': {'csr': csr}}},
        grains={'nodename': 'qubesair-console'}))


def fields(state, function):
    return {k: v for item in state[function] if isinstance(item, dict)
            for k, v in item.items()}


class RPCTests(unittest.TestCase):
    def setUp(self):
        self.csr = {'enabled': True}
        for prefix in ('issue_bin', 'list_endpoints', 'relay_call', 'relay_bootstrap'):
            self.csr[prefix + '_source'] = 'salt://qubesair/files/' + prefix
            self.csr[prefix + '_sha256'] = 'a' * 64

    def test_console_rejects_either_missing_digest(self):
        for key in ('issue_bin_sha256', 'list_endpoints_sha256'):
            with self.subTest(key=key):
                states = render('grpc-console', {**self.csr, key: ''})
                self.assertIn('grpc-console-issue-sha-required', states)
                self.assertNotIn('grpc-console-issue-bin', states)

    def test_console_helpers_and_boot_script_are_persistent(self):
        states = render('grpc-console', self.csr)
        for name in ('issue-bin', 'issue-service', 'list-endpoints-bin', 'endpoints-service'):
            file = fields(states['grpc-console-' + name], 'file.managed')
            self.assertTrue(file['name'].startswith('/rw/config/qubesair-rpc/'))
            self.assertEqual(file['user'], 'root')
        boot = fields(states['grpc-console-boot'], 'file.managed')
        self.assertIn('/etc/qubes-rpc/qubesair.IssueRelayCert', boot['contents'])
        self.assertIn('/etc/qubes-rpc/qubesair.RemoteEndpoints', boot['contents'])
        self.assertIn('/rw/config/qubesair-rpc/boot.sh',
                      fields(states['grpc-console-rc-local'], 'file.blockreplace')['content'])

    def test_relay_boot_code_is_outside_user_owned_identity_directory(self):
        states = render('grpc-csr-relay', self.csr)
        for name in ('call-bin', 'bootstrap-bin', 'boot-script', 'refresh-endpoints'):
            file = fields(states['grpc-csr-relay-' + name], 'file.managed')
            self.assertTrue(file['name'].startswith('/rw/config/qubesair-relay-runtime/'))
            self.assertEqual(file['user'], 'root')

    def test_handler_preserves_service_arguments_and_rejects_bad_ones(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake = root / 'relay-call'
            fake.write_text('#!/bin/sh\nfor arg do printf "%s\\n" "$arg"; done\n')
            fake.chmod(0o755)
            handler = root / 'handler'
            source = (ROOT / 'salt/mgmt/remotevm/files/qubesair.GrpcProxy').read_text()
            handler.write_text(source.replace('/usr/local/bin/relay-call', str(fake)))
            (root / 'secrets.env').write_text('')
            env = {**os.environ, 'QUBES_AIR_DATA_DIR': tmp,
                   'QUBES_AIR_RELAY_DIR': str(root / 'absent')}
            def call(argument):
                return subprocess.run(['bash', str(handler), argument], env=env,
                                      text=True, capture_output=True, timeout=5)
            for wire, expected in [('qubesair.Ping+', 'qubesair.Ping'),
                                   ('qubes.StartApp+editor', 'qubes.StartApp+editor')]:
                result = call('remote-qa+' + wire)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines()[-1], expected)
                self.assertEqual(result.stdout.splitlines()[-2], 'qa')
            nested = call('remote-remote-qa+qubesair.Ping+')
            self.assertEqual(nested.stdout.splitlines()[-2], 'remote-qa')
            for wire in ('qubesair.Exec+../bad', 'qubesair.Exec+bad space',
                         'qubesair.Exec+' + 'x' * 128):
                self.assertEqual(call('remote-qa+' + wire).returncode, 126)

    def test_endpoint_refresh_maps_bare_names_and_fails_without_partial_writes(self):
        states = render('grpc-csr-relay', self.csr)
        script = fields(states['grpc-csr-relay-refresh-endpoints'], 'file.managed')['contents']
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            handler = root / 'refresh'; handler.write_text(script)
            fetch = root / 'qrexec-client-vm'
            fetch.write_text('#!/bin/sh\nprintf "%s" "$QA_ENDPOINTS"\nexit "${QA_FETCH_EXIT:-0}"\n')
            fetch.chmod(0o755)
            write = root / 'qubesdb-write'
            write.write_text('#!/bin/sh\nprintf "%s %s\\n" "$1" "$2" >> "$QA_WRITES"\n')
            write.chmod(0o755)
            log = root / 'writes'
            env = {**os.environ, 'PATH': tmp + ':' + os.environ['PATH'],
                   'QA_WRITES': str(log)}
            def call(endpoints, failed=False):
                log.write_text('')
                return subprocess.run(['bash', str(handler)], text=True, capture_output=True,
                                      env={**env, 'QA_ENDPOINTS': endpoints,
                                           'QA_FETCH_EXIT': '1' if failed else '0'}, timeout=5)
            valid = 'qa-test 192.0.2.1:8443\nremote-nested 192.0.2.2:8443\n'
            self.assertEqual(call(valid).returncode, 0)
            self.assertEqual(log.read_text(), '/remote-endpoint/remote-qa-test 192.0.2.1:8443\n'
                             '/remote-endpoint/remote-remote-nested 192.0.2.2:8443\n')
            for invalid in ('bad/name 192.0.2.3:8443', 'bad 999.0.0.1:8443',
                            'bad 192.0.2.3:0', 'bad 192.0.2.3:65536',
                            'bad 192.0.2.3:8443 extra'):
                with self.subTest(invalid=invalid):
                    self.assertNotEqual(call(valid + invalid).returncode, 0)
                    self.assertEqual(log.read_text(), '')
            self.assertNotEqual(call('', failed=True).returncode, 0)
            self.assertEqual(call('').returncode, 0)


if __name__ == '__main__':
    unittest.main()
