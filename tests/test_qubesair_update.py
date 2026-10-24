# SPDX-License-Identifier: MIT
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import jinja2

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
                           ('backup', {'sshfs': {'host': 'nas;id'}}),
                           ('allow_gateway_ingress', 'true'), ('allow_gateway_ingress', 1)]:
            with self.subTest(key=key, value=value):
                self.manifest['qubesair'] = {key: value}
                self.save_manifest()
                with self.assertRaises(ValueError):
                    updater.install(self.source, self.target, self.backups)
                self.assertEqual((self.target / 'config.jinja').read_text(), self.config)
                self.assertFalse((self.target / 'qubesair').exists())

    def test_cleanup_overlay_accepts_only_the_exact_new_helpers(self):
        for name in ('mgmt/remotevm/register.sls', 'mgmt/remotevm/files/qubesair.RegisterRemoteVM',
                     'mgmt/remotevm/files/refresh-endpoints.py.jinja'):
            path = self.source / 'salt' / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('scoped helper fixture')
            self.manifest['files'][name] = hashlib.sha256(path.read_bytes()).hexdigest()
        self.save_manifest()
        planned = updater.prepare(self.source, self.target)
        self.assertIn(self.target / 'mgmt/remotevm/files/refresh-endpoints.py.jinja', planned)
        self.manifest['files']['mgmt/remotevm/files/arbitrary-helper'] = 'a' * 64
        self.save_manifest()
        with self.assertRaises(ValueError):
            updater.prepare(self.source, self.target)

    def test_digest_and_path_rejection(self):
        for name, digest in [('qubesair/console.sls', '0' * 64),
                             ('../outside', 'a' * 64), ('mgmt/remote-debug/configure.sls', 'a' * 64)]:
            self.manifest['files'] = {name: digest}
            self.save_manifest()
            with self.assertRaises(ValueError):
                updater.install(self.source, self.target, self.backups)
        self.assertEqual((self.target / 'config.jinja').read_text(), self.config)

    def test_connecttcp_overlay_delivers_the_exact_digest_checked_handler(self):
        name = 'mgmt/remotevm/files/qubesair.ConnectTCP'
        path = self.source / 'salt' / name
        path.parent.mkdir(parents=True)
        payload = b'ConnectTCP identity mapping fixture\n'
        path.write_bytes(payload)
        self.manifest['files'][name] = hashlib.sha256(payload).hexdigest()
        self.save_manifest()
        updater.install(self.source, self.target, self.backups)
        self.assertEqual((self.target / name).read_bytes(), payload)
        path.write_bytes(b'unapproved change')
        with self.assertRaisesRegex(ValueError, 'digest mismatch'):
            updater.install(self.source, self.target, self.backups)
        self.assertEqual((self.target / name).read_bytes(), payload)

    def test_symlink_destination_is_refused(self):
        (self.target / 'qubesair').symlink_to(self.source / 'salt/qubesair', target_is_directory=True)
        with self.assertRaises(ValueError):
            updater.prepare(self.source, self.target)

    def desktop_fixture(self):
        self.config = '{% set cfg = ' + repr({
            'other': {'keep': 'α'}, 'qubesair': {'enabled': True},
            'remotevm': {'relay': 'test-relay', 'grpc': {'csr': {
                'enabled': True, 'allowed_callers': ['work-client'], 'exec_action': 'ask',
                'service_grants': [{'source': 'work-client', 'target': 'remote-qa',
                                    'services': ['qubesair.FileCopy']}]}}},
        }) + ' %}\n'
        (self.target / 'config.jinja').write_text(self.config)
        name = 'mgmt/remotevm/files/qubesair.ConnectDesktop'
        path = self.source / 'salt' / name
        path.parent.mkdir(parents=True)
        payload = (SCRIPT.parent.parent / 'salt' / name).read_bytes()
        path.write_bytes(payload)
        self.manifest['files'][name] = hashlib.sha256(payload).hexdigest()
        self.manifest['remotevm'] = {'grpc': {'csr': {'desktop_grants': [
            {'source': 'work-client', 'target': 'remote-qa'}]}}}
        self.save_manifest()
        return name, payload

    def desktop_config(self):
        return jinja2.Environment().from_string(
            (self.target / 'config.jinja').read_text()).module.cfg

    def test_desktop_overlay_installs_exact_handler_and_grant_then_revokes(self):
        name, payload = self.desktop_fixture()
        updater.install(self.source, self.target, self.backups)
        self.assertEqual((self.target / name).read_bytes(), payload)
        csr = self.desktop_config()['remotevm']['grpc']['csr']
        self.assertEqual(csr['desktop_grants'], [{'source': 'work-client', 'target': 'remote-qa'}])
        self.assertEqual(csr['allowed_callers'], ['work-client'])
        self.assertEqual(csr['exec_action'], 'ask')
        self.assertEqual(csr['service_grants'][0]['services'], ['qubesair.FileCopy'])
        self.assertEqual(self.desktop_config()['other'], {'keep': 'α'})
        snapshots = list(self.backups.iterdir())
        updater.install(self.source, self.target, self.backups)
        self.assertEqual(list(self.backups.iterdir()), snapshots)
        self.manifest['remotevm']['grpc']['csr']['desktop_grants'] = []
        self.save_manifest()
        updater.install(self.source, self.target, self.backups)
        self.assertEqual(self.desktop_config()['remotevm']['grpc']['csr']['desktop_grants'], [])
        self.assertEqual((self.target / name).read_bytes(), payload)

    def test_desktop_overlay_rejects_tampered_handler_before_writes(self):
        name, _ = self.desktop_fixture()
        (self.source / 'salt' / name).write_bytes(b'unapproved change')
        with self.assertRaisesRegex(ValueError, 'digest mismatch'):
            updater.install(self.source, self.target, self.backups)
        self.assertEqual((self.target / 'config.jinja').read_text(), self.config)
        self.assertFalse((self.target / name).exists())
        self.assertEqual(list(self.backups.iterdir()), [])

    def test_desktop_grants_validate_shape_names_and_limit(self):
        grant = {'source': 'work-client', 'target': 'remote-qa'}
        updater.check_remote_patch({'grpc': {'csr': {'desktop_grants': [grant] * 32}}})
        updater.check_remote_patch({'grpc': {'csr': {'desktop_grants': [
            {'source': 'a' * 31, 'target': 'remote-' + 'x' * 24}]}}})
        invalid = [None, 'all', {}, [None], [grant] * 33, [dict(grant, services=['*'])],
                   [{'source': 'work-client'}]]
        for key, value in [('source', '@anyvm'), ('source', 'dom0\n*'),
                           ('source', 'a' * 32), ('source', 'é'), ('source', 42),
                           ('target', 'qa'), ('target', 'remote-'), ('target', 'remote-*'),
                           ('target', 'remote-qa+10005'), ('target', 'remote-qa\nallow'),
                           ('target', 'remote-' + 'x' * 25), ('target', [])]:
            invalid.append([dict(grant, **{key: value})])
        for grants in invalid:
            with self.subTest(grants=grants), self.assertRaises(ValueError):
                updater.check_remote_patch({'grpc': {'csr': {'desktop_grants': grants}}})

    def test_desktop_grant_cannot_add_or_bypass_existing_caller_scope(self):
        name, _ = self.desktop_fixture()
        for csr in ({'desktop_grants': [{'source': 'unlisted', 'target': 'remote-qa'}]},
                    {'desktop_grants': [{'source': 'work', 'target': 'remote-qa'}]},
                    {'desktop_grants': [], 'allowed_callers': ['unlisted']}):
            with self.subTest(csr=csr):
                self.manifest['remotevm']['grpc']['csr'] = csr
                self.save_manifest()
                with self.assertRaises(ValueError):
                    updater.install(self.source, self.target, self.backups)
                self.assertEqual((self.target / 'config.jinja').read_text(), self.config)
                self.assertFalse((self.target / name).exists())
                self.assertEqual(list(self.backups.iterdir()), [])

    def test_desktop_grants_reject_malformed_existing_callers(self):
        name, _ = self.desktop_fixture()
        for callers in ('work-client', None, {'work-client': True}):
            with self.subTest(callers=callers):
                cfg = jinja2.Environment().from_string(self.config).module.cfg
                cfg['remotevm']['grpc']['csr']['allowed_callers'] = callers
                previous = '{% set cfg = ' + repr(cfg) + ' %}\n'
                (self.target / 'config.jinja').write_text(previous)
                with self.assertRaisesRegex(ValueError, 'existing allowed caller'):
                    updater.install(self.source, self.target, self.backups)
                self.assertEqual((self.target / 'config.jinja').read_text(), previous)
                self.assertFalse((self.target / name).exists())

    def test_desktop_grants_use_the_same_default_caller_as_policy(self):
        self.desktop_fixture()
        cfg = self.desktop_config()
        del cfg['remotevm']['grpc']['csr']['allowed_callers']
        previous = '{% set cfg = ' + repr(cfg) + ' %}\n'
        patch = {'grpc': {'csr': {'desktop_grants': [
            {'source': 'test-relay', 'target': 'remote-qa'}]}}}
        updated = updater.patch_config(previous, {}, patch)
        self.assertEqual(jinja2.Environment().from_string(updated).module.cfg[
            'remotevm']['grpc']['csr']['desktop_grants'][0]['source'], 'test-relay')

    def test_desktop_write_failure_restores_prior_configuration(self):
        name, _ = self.desktop_fixture()
        replace = updater.replace_file

        def fail_config(path, content, mode):
            if path.name == 'config.jinja':
                raise OSError('injected full disk')
            replace(path, content, mode)

        with mock.patch.object(updater, 'replace_file', side_effect=fail_config):
            with self.assertRaises(OSError):
                updater.install(self.source, self.target, self.backups)
        self.assertEqual((self.target / 'config.jinja').read_text(), self.config)
        self.assertFalse((self.target / name).exists())

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
