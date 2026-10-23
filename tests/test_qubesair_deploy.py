# SPDX-License-Identifier: MIT
"""Render deployment contracts and execute their failure gates locally."""
import copy
import json
import pathlib
import subprocess
import tempfile
import unittest

import jinja2
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]


def render(state, qa):
    env = jinja2.Environment(loader=jinja2.ChoiceLoader([
        jinja2.DictLoader({'config.jinja': '{% set cfg = supplied %}'}),
        jinja2.FileSystemLoader(ROOT / 'salt'),
    ]), undefined=jinja2.StrictUndefined)
    return yaml.safe_load(env.get_template(state).render(
        supplied={'qubesair': qa}, grains={'nodename': 'qubesair-console'},
        salt={'user.info': lambda _: {'uid': 1000, 'gid': 1000}}))


def args(state, function):
    return {key: value for entry in state[function] if isinstance(entry, dict)
            for key, value in entry.items()}


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.qa = {'enabled': True, 'data_dir': self.tmp.name,
                   'console_binary_sha256': 'a' * 64,
                   'console_web_source': 'salt://web.tar.gz',
                   'console_web_sha256': 'b' * 64,
                   'backup': {'enabled': True, 'binary_sha256': 'c' * 64}}

    def test_preflight_stops_failed_candidate_before_live_files(self):
        states = render('qubesair/console.sls', self.qa)
        gate = args(states['qubesair-console-database-preflight'], 'cmd.run')
        self.assertTrue(gate['failhard'])
        self.assertEqual(gate['runas'], 'user')
        required = gate['require_in']
        for name in ('binary', 'env', 'preflight', 'unit', 'web-archive',
                     'ingress-helper', 'ingress-config', 'ingress-hook'):
            self.assertIn({'file': 'qubesair-console-' + name}, required)
        path = pathlib.Path(self.tmp.name)
        (path / 'bin').mkdir()
        candidate = path / 'bin/qubes-air-console.candidate'
        candidate.write_text('#!/bin/sh\n[ "$1" = --version ]\n')
        candidate.chmod(0o755)
        cmd = gate['name']
        # First installation can proceed; an existing DB must invoke the check,
        # whose failure must propagate (not be hidden by the stateful printf).
        self.assertEqual(subprocess.run(['sh', '-eu'], input=cmd,
                                       text=True, capture_output=True).returncode, 0)
        (path / 'qubes-air.db').touch()
        self.assertNotEqual(subprocess.run(['sh', '-eu'], input=cmd,
                                          text=True, capture_output=True).returncode, 0)
        (path / 'qubes-air.db').unlink()
        (path / 'qubes-air.db').symlink_to(path / 'missing.db')
        self.assertNotEqual(subprocess.run(['sh', '-eu'], input=cmd,
                                          text=True, capture_output=True).returncode, 0)

    def test_reapply_does_not_unconditionally_restart(self):
        states = render('qubesair/console.sls', self.qa)
        service = args(states['qubesair-console-service'], 'service.running')
        self.assertIn({'file': 'qubesair-console-binary'}, service['watch'])
        health = args(states['qubesair-console-start'], 'cmd.run')
        self.assertNotIn('restart', health['name'])
        self.assertIn({'service': 'qubesair-console-service'}, health['require'])
        env = args(states['qubesair-console-env'], 'file.managed')['contents']
        self.assertIn('QUBES_AIR_ORCHESTRATOR_PROVISION_WAIT_SECONDS=600', env)

    def test_console_ingress_survives_firewall_reload_and_is_opt_in(self):
        states = render('qubesair/console.sls', self.qa)
        self.assertIn('qubesair.console-ingress', states['include'])
        for enabled in (False, True):
            cfg = {**self.qa, 'allow_gateway_ingress': enabled, 'listen': '0.0.0.0:8080'}
            states = render('qubesair/console-ingress.sls', cfg)
            config = json.loads(args(states['qubesair-console-ingress-config'], 'file.managed')['contents'])
            self.assertEqual(config, {'enabled': enabled, 'qube': 'qubesair-console', 'listen': '0.0.0.0:8080'})
            hook = args(states['qubesair-console-ingress-hook'], 'file.blockreplace')
            self.assertEqual(hook['name'], '/rw/config/qubes-firewall-user-script')
            self.assertIn('/rw/config/qubesair-ingress/apply.py', hook['content'])
            self.assertNotIn('|| true', hook['content'])
            self.assertNotIn('service.running', states['qubesair-console-ingress-apply'])
            # Salt's cmd.run state supplies python_shell itself; passing it as
            # state kwargs raises duplicate-keyword before the helper executes.
            command = args(states['qubesair-console-ingress-apply'], 'cmd.run')
            self.assertNotIn('python_shell', command)
            self.assertEqual(command['name'], '/rw/config/qubesair-ingress/apply.py')
            boot = args(states['qubesair-console-ingress-boot-hook'], 'file.blockreplace')
            self.assertEqual(boot['name'], '/rw/config/rc.local')
            self.assertEqual(boot['content'].strip(), '/rw/config/qubesair-ingress/apply.py')
            self.assertIn({'file': 'qubesair-console-ingress-boot-hook'}, command['require'])

    def test_backup_refuses_local_directory_before_create_and_prune(self):
        states = render('qubesair/backup.sls', self.qa)
        unit = args(states['qubesair-backup-unit'], 'file.managed')['contents']
        self.assertIn('ExecStartPre=/usr/bin/mountpoint -q /secure/offhost', unit)
        self.assertLess(unit.index('ExecStartPre='), unit.index(' create '))
        self.assertLess(unit.index(' create '), unit.index(' prune '))
        self.assertFalse(args(states['qubesair-backup-env-file'], 'file.managed')['replace'])

    def test_sshfs_authentication_and_mount_dependency(self):
        self.qa['backup']['sshfs'] = {'enabled': True, 'host': 'backup.example',
                                      'user': 'qa-backup', 'path': '/archives'}
        mount = render('qubesair/backup-mount.sls', self.qa)
        parent = args(mount['qubesair-backup-mount-parent'], 'file.directory')
        self.assertEqual(parent['mode'], '0711')
        point = args(mount['qubesair-backup-mountpoint'], 'file.directory')
        self.assertIn({'file': 'qubesair-backup-mount-parent'}, point['require'])
        unit = args(mount['qubesair-backup-mount-unit'], 'file.managed')['contents']
        for required in ('StrictHostKeyChecking=yes', 'BatchMode=yes',
                         'UserKnownHostsFile=', 'IdentityFile=', 'default_permissions'):
            self.assertIn(required, unit)
        backup = render('qubesair/backup.sls', self.qa)
        unit = args(backup['qubesair-backup-unit'], 'file.managed')['contents']
        self.assertIn('Requires=secure-offhost.mount', unit)
        self.qa['backup']['offhost_dir'] = '/some/other/path'
        mount = render('qubesair/backup-mount.sls', self.qa)
        self.assertIn('qubesair-backup-mount-path-required', mount)
        self.assertNotIn('qubesair-backup-mount-unit', mount)

    def test_recorded_pins_match_config_and_missing_agent_url_fails(self):
        cfg = jinja2.Environment().from_string((ROOT / 'salt/config.jinja').read_text()).module.cfg
        qa = cfg['qubesair']
        record = json.loads((ROOT / 'salt/qubesair/artifacts.json').read_text())
        artifacts = {}
        for build in record['builds']:
            self.assertRegex(build['source_revision'], r'^[a-f0-9]{40}$')
            self.assertEqual(build['platform'], 'linux/amd64')
            for name, digest in build['artifacts'].items():
                self.assertNotIn(name, artifacts)
                self.assertRegex(digest, r'^[a-f0-9]{64}$')
                artifacts[name] = (digest, build['version'])
        for source, digest in [('console_binary_source', 'console_binary_sha256'),
                               ('console_web_source', 'console_web_sha256')]:
            self.assertEqual(artifacts[qa[source].rsplit('/', 1)[-1]][0], qa[digest])
        backup = qa['backup']
        self.assertEqual(artifacts[backup['binary_source'].rsplit('/', 1)[-1]][0], backup['binary_sha256'])
        agent = 'qubes-air-agent_' + qa['agent_package_version'] + '_amd64.deb'
        self.assertEqual(artifacts[agent], (qa['agent_package_sha256'], qa['agent_package_version']))
        csr = cfg['remotevm']['grpc']['csr']
        for prefix in ('issue_bin', 'list_endpoints', 'relay_call', 'relay_bootstrap'):
            self.assertEqual(artifacts[csr[prefix + '_source'].rsplit('/', 1)[-1]][0],
                             csr[prefix + '_sha256'])
        states = render('qubesair/console.sls', qa)
        self.assertIn('qubesair-console-agent-pin-required', states)
        self.assertNotIn('qubesair-console-binary', states)

    def test_unpinned_binary_fails_closed(self):
        cfg = copy.deepcopy(self.qa)
        cfg['console_binary_sha256'] = ''
        states = render('qubesair/console.sls', cfg)
        self.assertIn('qubesair-console-binary-sha-required', states)
        self.assertNotIn('qubesair-console-binary', states)


if __name__ == '__main__':
    unittest.main()
