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

    def test_endpoint_cleanup_rpc_and_lock_survive_reboot(self):
        states = render('grpc-csr-relay', self.csr)
        lock = fields(states['grpc-csr-relay-endpoints-lock'], 'file.managed')
        self.assertEqual(lock['user'], 'user')
        self.assertFalse(lock['replace'])
        boot = fields(states['grpc-csr-relay-boot-script'], 'file.managed')['contents']
        self.assertIn('/etc/qubes-rpc/qubesair.ForgetEndpoint', boot)
        self.assertIn('refresh-endpoints.py', boot)
        self.assertNotIn('refresh-endpoints.sh', boot)
        source = fields(states['grpc-csr-relay-refresh-endpoints'], 'file.managed')
        self.assertEqual(source['template'], 'jinja')
        self.assertTrue((ROOT / 'salt' / source['source'].removeprefix('salt://')).is_file())

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

    def test_connecttcp_keeps_lookup_name_and_strips_one_agent_prefix(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake = root / 'relay-call'
            fake.write_text('#!/bin/sh\nfor arg do printf "%s\\n" "$arg"; done\n')
            fake.chmod(0o755)
            qdb = root / 'qubesdb-read'
            qdb.write_text('#!/bin/sh\nprintf "%s\\n" "$1" > "$QA_LOOKUP"\nprintf "192.0.2.1:8443\\n"\n')
            qdb.chmod(0o755)
            handler = root / 'handler'
            source = (ROOT / 'salt/mgmt/remotevm/files/qubesair.ConnectTCP').read_text()
            handler.write_text(source.replace('/usr/local/bin/relay-call', str(fake)))
            (root / 'relay.crt').touch()
            lookup = root / 'lookup'
            env = {**os.environ, 'PATH': tmp + ':' + os.environ['PATH'],
                   'QUBES_AIR_RELAY_DIR': tmp, 'QA_LOOKUP': str(lookup)}
            for local, agent in [('remote-qa', 'qa'), ('remote-remote-qa', 'remote-qa')]:
                with self.subTest(local=local):
                    result = subprocess.run(['bash', str(handler), local + '+10000'],
                                            env=env, text=True, capture_output=True, timeout=5)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(lookup.read_text().strip(), '/remote-endpoint/' + local)
                    self.assertEqual(result.stdout.splitlines()[-2:], [agent, '10000'])
            for bad in ('remote-+10000', 'qa+10000', 'remote-qa+22', 'remote-qa+10000+extra'):
                lookup.unlink(missing_ok=True)
                result = subprocess.run(['bash', str(handler), bad], env=env,
                                        text=True, capture_output=True, timeout=5)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')
                self.assertFalse(lookup.exists())



if __name__ == '__main__':
    unittest.main()
