# SPDX-License-Identifier: MIT
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/update-qubesair.py'
SPEC = importlib.util.spec_from_file_location('updater', SCRIPT)
updater = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(updater)


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / 'source'
        self.target = self.root / 'target'
        self.backups = self.root / 'backups'
        for path in (self.source / 'salt/qubesair', self.target, self.backups):
            path.mkdir(parents=True)
        self.config = '{# 用户配置 #}\n{% set cfg = {"other": {"keep": "α"}, "qubesair": {"enabled": True, "listen": "127.0.0.1:8080"}} %}\n'
        (self.target / 'config.jinja').write_text(self.config)
        (self.target / 'unrelated.sls').write_text('keep this exactly\n')
        payload = b'new console state\n'
        (self.source / 'salt/qubesair/console.sls').write_bytes(payload)
        self.manifest = {'files': {'qubesair/console.sls': hashlib.sha256(payload).hexdigest()},
                         'qubesair': {'provision_wait_seconds': 600}}
        self.save_manifest()

    def save_manifest(self):
        (self.source / 'qubesair-deployment.json').write_text(json.dumps(self.manifest))

    def test_scoped_update_backup_and_repeat(self):
        updater.install(self.source, self.target, self.backups)
        content = (self.target / 'config.jinja').read_text()
        self.assertIn('"other": {"keep": "α"}', content)
        self.assertIn("'listen': '127.0.0.1:8080'", content)
        self.assertIn("'provision_wait_seconds': 600", content)
        self.assertEqual((self.target / 'unrelated.sls').read_text(), 'keep this exactly\n')
        snapshots = list(self.backups.iterdir())
        self.assertEqual((snapshots[0] / 'config.jinja').read_text(), self.config)
        updater.install(self.source, self.target, self.backups)
        self.assertEqual(list(self.backups.iterdir()), snapshots)

    def test_invalid_overlays_leave_everything_untouched(self):
        for key, value in [('unknown', 'x'), ('console_binary_sha256', 'bad'),
                           ('console_binary_source', 'salt://qubesair/files/../other'),
                           ('provision_wait_seconds', 0), ('backup', {'offhost_dir': '/tmp/../etc'}),
                           ('backup', {'sshfs': {'host': 'nas;id'}})]:
            with self.subTest(key=key, value=value):
                self.manifest['qubesair'] = {key: value}
                self.save_manifest()
                with self.assertRaises(ValueError):
                    updater.install(self.source, self.target, self.backups)
                self.assertEqual((self.target / 'config.jinja').read_text(), self.config)
                self.assertFalse((self.target / 'qubesair').exists())

    def test_digest_and_path_rejection(self):
        for name, digest in [('qubesair/console.sls', '0' * 64),
                             ('../outside', 'a' * 64), ('mgmt/remote-debug/configure.sls', 'a' * 64)]:
            self.manifest['files'] = {name: digest}
            self.save_manifest()
            with self.assertRaises(ValueError):
                updater.install(self.source, self.target, self.backups)
        self.assertEqual((self.target / 'config.jinja').read_text(), self.config)

    def test_symlink_destination_is_refused(self):
        (self.target / 'qubesair').symlink_to(self.source / 'salt/qubesair', target_is_directory=True)
        with self.assertRaises(ValueError):
            updater.prepare(self.source, self.target)

    def test_remote_overlay_cannot_open_general_services(self):
        for target, services in [('@anyvm', ['qubesair.Exec']),
                                 ('qa-target', ['qubes.VMShell']),
                                 ('qa-target', [])]:
            patch = {'grpc': {'csr': {'service_grants': [{'source': 'qubesair-console',
                     'target': target, 'services': services}]}}}
            with self.assertRaises(ValueError):
                updater.check_remote_patch(patch)
        with self.assertRaises(ValueError):
            updater.check_remote_patch({'grpc': {'csr': {'exec_action': 'allow'}}})

    def test_write_failure_rolls_back(self):
        replace = updater.replace_file

        def fail_config(path, content, mode):
            if path.name == 'config.jinja':
                raise OSError('injected full disk')
            replace(path, content, mode)

        with mock.patch.object(updater, 'replace_file', side_effect=fail_config):
            with self.assertRaises(OSError):
                updater.install(self.source, self.target, self.backups)
        self.assertFalse((self.target / 'qubesair/console.sls').exists())
        self.assertEqual((self.target / 'config.jinja').read_text(), self.config)

    def test_rpc_updates_require_complete_pins_and_preserve_policy(self):
        patch = {'grpc': {'csr': {'relay_call_source': 'salt://qubesair/files/relay-call-v1',
                                'relay_call_sha256': 'a' * 64}}}
        updater.check_remote_patch(patch)
        config = '{% set cfg = {"qubesair": {}, "remotevm": {"relay": "relay", "grpc": {"csr": {"exec_action": "ask"}}}} %}'
        result = updater.patch_config(config, {}, patch)
        self.assertIn("'exec_action': 'ask'", result)
        for invalid in ({'relay_call_source': patch['grpc']['csr']['relay_call_source']},
                        {'relay_call_source': 'salt://other/tool', 'relay_call_sha256': 'a' * 64},
                        {'relay_call_source': patch['grpc']['csr']['relay_call_source'], 'relay_call_sha256': 'bad'},
                        {'relay_dir': '/tmp'}, {'enabled': True}, {'service_grants': 'all'}):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                updater.check_remote_patch({'grpc': {'csr': invalid}})


if __name__ == '__main__':
    unittest.main()
