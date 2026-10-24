# SPDX-License-Identifier: MIT
"""The fixed desktop route is opt-in, target scoped and persistent."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import jinja2
import yaml

from test_qubesair_rpc import fields, render

ROOT = Path(__file__).resolve().parents[1]
SERVICE = 'qubesair.ConnectDesktop'


def policy(grants):
    env = jinja2.Environment(loader=jinja2.ChoiceLoader([
        jinja2.DictLoader({'config.jinja': '{% set cfg = supplied %}'}),
        jinja2.FileSystemLoader(ROOT / 'salt'),
    ]), undefined=jinja2.StrictUndefined)
    cfg = {'remotevm': {'relay': 'test-relay', 'grpc': {'csr': {
        'enabled': True, 'allowed_callers': ['work-client'], 'desktop_grants': grants}}}}
    return yaml.safe_load(env.get_template('mgmt/remotevm/grpc-policy.sls').render(
        supplied=cfg, grains={'nodename': 'dom0'}))


class DesktopPolicyTests(unittest.TestCase):
    def test_default_denies_and_exact_grant_has_no_wildcard_argument(self):
        for grants in ([], [{'source': 'work-client', 'target': 'remote-qa'}]):
            states = policy(grants)
            contents = fields(states['grpc-csr-policy'], 'file.managed')['contents']
            rules = [line.strip() for line in contents.splitlines() if line.strip().startswith(SERVICE + ' ')]
            expected = [SERVICE + ' * @anyvm @anyvm deny']
            if grants:
                expected.insert(0, SERVICE + ' +remote-qa work-client test-relay allow')
            self.assertEqual(rules, expected)

    def test_invalid_grants_do_not_replace_policy(self):
        baseline = {'source': 'work-client', 'target': 'remote-qa'}
        changes = [{'source': 'unlisted'}, {'source': '@anyvm'}, {'source': 'dom0'},
                   {'target': '@anyvm'}, {'target': 'qa'}, {'target': 'remote-'},
                   {'target': 'remote-qa+10005'}, {'target': 'remote-qa\n* * @anyvm @anyvm allow'},
                   {'target': 'remote-' + 'x' * 25}, {'target': ''}]
        for change in changes:
            with self.subTest(change=change):
                states = policy([{**baseline, **change}])
                self.assertIn('grpc-desktop-grants-invalid', states)
                self.assertNotIn('grpc-csr-policy', states)
        self.assertIn('grpc-desktop-grants-invalid', policy([baseline] * 33))
        self.assertIn('grpc-csr-policy', policy([baseline] * 32))

    def test_malformed_grant_container_cannot_render_policy(self):
        for grants in (None, 'remote-qa', {'source': 'work-client'}, [None]):
            with self.subTest(grants=grants), self.assertRaises((TypeError, jinja2.UndefinedError)):
                policy(grants)

    def test_handler_and_boot_link_are_root_owned_and_persistent(self):
        csr = {'enabled': True, 'relay_call_source': 'salt://qubesair/files/call',
               'relay_call_sha256': 'a' * 64, 'relay_bootstrap_source': 'salt://qubesair/files/bootstrap',
               'relay_bootstrap_sha256': 'b' * 64}
        states = render('grpc-csr-relay', csr)
        handler = fields(states['grpc-csr-relay-connectdesktop'], 'file.managed')
        self.assertEqual(handler['name'], '/rw/config/qubesair-relay-runtime/bin/' + SERVICE)
        self.assertEqual((handler['user'], handler['group'], handler['mode']), ('root', 'root', '0755'))
        self.assertEqual(handler['source'], 'salt://mgmt/remotevm/files/' + SERVICE)
        boot = fields(states['grpc-csr-relay-boot-script'], 'file.managed')['contents']
        self.assertIn('ln -sf ' + handler['name'] + ' /etc/qubes-rpc/' + SERVICE, boot)
        self.assertIn({'file': 'grpc-csr-relay-connectdesktop'},
                      fields(states['grpc-csr-relay-activate-now'], 'cmd.run')['require'])


class DesktopHandlerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.lookup = self.root / 'lookup'
        self.dispatch = self.root / 'dispatch'
        fake = self.root / 'relay-call'
        fake.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$QA_DISPATCH"\ncat\nexit "${QA_EXEC_RC:-0}"\n')
        fake.chmod(0o755)
        qdb = self.root / 'qubesdb-read'
        qdb.write_text('#!/bin/sh\nprintf "%s\\n" "$1" > "$QA_LOOKUP"\n'
                       'printf "%s\\n" "$QA_ENDPOINT"\nexit "${QA_LOOKUP_RC:-0}"\n')
        qdb.chmod(0o755)
        (self.root / 'relay.crt').touch()
        self.env = {**os.environ, 'PATH': str(self.root) + ':' + os.environ['PATH'],
                    'QUBES_AIR_RELAY_DIR': str(self.root), 'QA_LOOKUP': str(self.lookup),
                    'QA_DISPATCH': str(self.dispatch), 'QA_ENDPOINT': '192.0.2.1:8443'}
        self.handlers = {}
        for name in (SERVICE, 'qubesair.ConnectTCP'):
            source = (ROOT / 'salt/mgmt/remotevm/files' / name).read_text()
            handler = self.root / name
            handler.write_text(source.replace('/usr/local/bin/relay-call', str(fake)))
            self.handlers[name] = handler

    def call(self, args, service=SERVICE, payload=b''):
        return subprocess.run(['bash', str(self.handlers[service]), *args], env=self.env,
                              input=payload, capture_output=True, timeout=5)

    def test_fixed_selector_preserves_binary_stream_and_strips_one_prefix(self):
        for local, agent in [('remote-qa', 'qa'), ('remote-remote-qa', 'remote-qa')]:
            result = self.call([local], payload=b'\x00\xffdesktop fixture\n')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, b'\x00\xffdesktop fixture\n')
            self.assertEqual(self.lookup.read_text().strip(), '/remote-endpoint/' + local)
            self.assertEqual(self.dispatch.read_text().splitlines(), [
                '-stream', '-timeout', '12h', '-cert', str(self.root / 'relay.crt'),
                '-key', str(self.root / 'relay.key'), '-ca', str(self.root / 'ca.crt'),
                '-addr', '192.0.2.1:8443', agent, 'desktop'])

    def test_invalid_arguments_are_rejected_before_lookup(self):
        for args in ([], [''], ['qa'], ['remote-'], ['remote-qa+10005'], ['remote-../qa'],
                     ['remote-qa\nextra'], ['remote-qa', 'extra']):
            with self.subTest(args=args):
                result = self.call(args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b'')
                self.assertFalse(self.lookup.exists())
                self.assertFalse(self.dispatch.exists())

    def test_transport_failure_is_returned_without_retry(self):
        self.env['QA_EXEC_RC'] = '73'
        result = self.call(['remote-qa'], payload=b'fixture bytes')
        self.assertEqual(result.returncode, 73)
        self.assertEqual(result.stdout, b'fixture bytes')
        self.assertEqual(self.dispatch.read_text().splitlines().count('-stream'), 1)

    def test_missing_or_invalid_endpoint_and_identity_never_dispatch(self):
        for endpoint in ('', '999.0.0.1:8443', '192.0.2.1:0', '192.0.2.1:65536',
                         'host.example:8443', '192.0.2.1:8443\nextra'):
            with self.subTest(endpoint=endpoint):
                self.env['QA_ENDPOINT'] = endpoint
                result = self.call(['remote-qa'])
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.dispatch.exists())
        self.env['QA_ENDPOINT'] = '192.0.2.1:8443'
        self.env['QA_LOOKUP_RC'] = '1'
        self.assertNotEqual(self.call(['remote-qa']).returncode, 0)
        self.assertFalse(self.dispatch.exists())
        del self.env['QA_LOOKUP_RC']
        (self.root / 'relay.crt').unlink()
        self.assertNotEqual(self.call(['remote-qa']).returncode, 0)
        self.assertFalse(self.dispatch.exists())

    def test_old_desktop_tcp_port_is_refused_before_lookup(self):
        result = self.call(['remote-qa+10005'], service='qubesair.ConnectTCP')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b'')
        self.assertFalse(self.lookup.exists())
        self.assertFalse(self.dispatch.exists())


if __name__ == '__main__':
    unittest.main()
