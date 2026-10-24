# SPDX-License-Identifier: MIT
"""Pinned HTTPS artifacts must be staged with bounded I/O before live files."""
import json
import unittest

import jinja2
import yaml

from test_qubesair_deploy import ROOT, args, render as render_console
from test_qubesair_rpc import render as render_rpc

CACHE = '/rw/config/qubesair-artifacts/cache/'


class ArtifactStateTests(unittest.TestCase):
    def test_https_artifacts_use_local_verified_sources_and_bounded_stage(self):
        qa = {'enabled': True, 'console_binary_source': 'https://releases.example/console',
              'console_binary_sha256': 'a' * 64,
              'console_web_source': 'https://releases.example/web.tar.gz',
              'console_web_sha256': 'b' * 64,
              'backup': {'enabled': True, 'binary_source': 'https://releases.example/backup',
                         'binary_sha256': 'c' * 64}}
        csr = {'enabled': True}
        for prefix in ('issue_bin', 'list_endpoints', 'relay_call', 'relay_bootstrap'):
            csr[prefix + '_source'] = 'https://releases.example/' + prefix
            csr[prefix + '_sha256'] = 'd' * 64
        cases = [
            (render_console('qubesair/console.sls', qa), 'console',
             ['qubesair-console-candidate', 'qubesair-console-binary']),
            (render_console('qubesair/console.sls', qa), 'web', ['qubesair-console-web-archive']),
            (render_console('qubesair/backup.sls', qa), 'backup', ['qubesair-backup-binary']),
            (render_rpc('grpc-console', csr), 'issuer', ['grpc-console-issue-bin']),
            (render_rpc('grpc-console', csr), 'endpoints', ['grpc-console-list-endpoints-bin']),
            (render_rpc('grpc-csr-relay', csr), 'relay-call', ['grpc-csr-relay-call-bin']),
            (render_rpc('grpc-csr-relay', csr), 'relay-bootstrap', ['grpc-csr-relay-bootstrap-bin']),
        ]
        for states, kind, live in cases:
            with self.subTest(kind=kind):
                for state in live:
                    source = args(states[state], 'file.managed')
                    self.assertEqual(source['source'], CACHE + kind)
                    self.assertRegex(source['source_hash'], r'^sha256=[a-f0-9]{64}$')
                self.assertIn('qubesair.artifact-fetch', states['include'])
                stage = args(states['qubesair-artifact-fetch-' + kind], 'cmd.run')
                self.assertEqual(stage['name'], '/usr/bin/python3 /rw/config/qubesair-artifacts/fetch.py ' + kind)
                self.assertEqual(stage['timeout'], 250)
                self.assertTrue(stage['stateful'])
                self.assertTrue(stage['failhard'])
                self.assertNotIn('python_shell', stage)
                self.assertEqual(stage['require_in'], [{'file': item} for item in live])
                config = args(states['qubesair-artifact-request-' + kind], 'file.managed')
                self.assertEqual(config['user'], 'root')
                request = json.loads(config['contents'])
                self.assertEqual(set(request), {'url', 'sha256'})
                self.assertTrue(request['url'].startswith('https://releases.example/'))

    def test_salt_sources_keep_native_digest_verification(self):
        qa = {'enabled': True, 'console_binary_source': 'salt://qubesair/files/qubes-air-console',
              'console_binary_sha256': 'a' * 64}
        states = render_console('qubesair/console.sls', qa)
        self.assertEqual(args(states['qubesair-console-candidate'], 'file.managed')['source'],
                         qa['console_binary_source'])
        self.assertNotIn('qubesair-artifact-fetch-console', states)

    def test_prefetch_only_writes_cache_for_enabled_target_roles(self):
        qa = {'enabled': True, 'qube': 'test-console',
              'console_binary_source': 'https://releases.example/console', 'console_binary_sha256': 'a' * 64,
              'console_web_source': 'https://releases.example/web', 'console_web_sha256': 'b' * 64,
              'backup': {'enabled': True, 'binary_source': 'https://releases.example/backup', 'binary_sha256': 'c' * 64}}
        csr = {'enabled': True, 'console_qube': 'test-console'}
        for prefix in ('issue_bin', 'list_endpoints', 'relay_call', 'relay_bootstrap'):
            csr[prefix + '_source'] = 'https://releases.example/' + prefix
            csr[prefix + '_sha256'] = 'd' * 64
        cfg = {'qubesair': qa, 'remotevm': {'relay': 'test-relay', 'grpc': {'csr': csr}}}
        env = jinja2.Environment(loader=jinja2.ChoiceLoader([
            jinja2.DictLoader({'config.jinja': '{% set cfg = supplied %}'}),
            jinja2.FileSystemLoader(ROOT / 'salt')]), undefined=jinja2.StrictUndefined)
        for node, expected in [('test-console', {'console', 'web', 'backup', 'issuer', 'endpoints'}),
                               ('test-relay', {'relay-call', 'relay-bootstrap'}),
                               ('other', set()), ('dom0', set())]:
            with self.subTest(node=node):
                states = yaml.safe_load(env.get_template('qubesair/artifact-prefetch.sls').render(
                    supplied=cfg, grains={'nodename': node}))
                seen = set()
                for name, state in states.items():
                    if name == 'include':
                        continue
                    if name.startswith('qubesair-artifact-request-'):
                        self.assertTrue(args(state, 'file.managed')['name'].startswith(
                            '/rw/config/qubesair-artifacts/requests/'))
                    elif name.startswith('qubesair-artifact-fetch-'):
                        seen.add(name.removeprefix('qubesair-artifact-fetch-'))
                        self.assertNotIn('require_in', args(state, 'cmd.run'))
                    else:
                        self.assertIn('test.fail_without_changes', state)
                self.assertEqual(seen, expected)
        qa['enabled'] = csr['enabled'] = False
        states = yaml.safe_load(env.get_template('qubesair/artifact-prefetch.sls').render(
            supplied=cfg, grains={'nodename': 'test-console'}))
        self.assertIn('qubesair-artifact-prefetch-target-required', states)


if __name__ == '__main__':
    unittest.main()
