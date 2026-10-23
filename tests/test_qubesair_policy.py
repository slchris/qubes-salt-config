# SPDX-License-Identifier: MIT
from pathlib import Path
import unittest
import jinja2
import yaml

ROOT = Path(__file__).resolve().parents[1]


def policy(grants):
    env = jinja2.Environment(loader=jinja2.ChoiceLoader([
        jinja2.DictLoader({'config.jinja': '{% set cfg = supplied %}'}),
        jinja2.FileSystemLoader(ROOT / 'salt'),
    ]), undefined=jinja2.StrictUndefined)
    cfg = {'remotevm': {'grpc': {'csr': {'enabled': True,
           'allowed_callers': ['qubesair-console'], 'service_grants': grants}}}}
    return yaml.safe_load(env.get_template('mgmt/remotevm/grpc-policy.sls').render(
        supplied=cfg, grains={'nodename': 'dom0'}))


class PolicyTests(unittest.TestCase):
    def test_exact_grant_precedes_prompt_and_deny(self):
        states = policy([{'source': 'qubesair-console', 'target': 'qa-closure',
                          'services': ['qubesair.Exec', 'qubesair.FileCopy']}])
        text = next(item['contents'] for item in states['grpc-csr-policy']['file.managed']
                    if 'contents' in item)
        for service in ('qubesair.Exec', 'qubesair.FileCopy'):
            exact = service + ' + qubesair-console qa-closure allow'
            self.assertIn(exact, text)
            self.assertLess(text.index(exact), text.index('* * @anyvm @tag:remote-zone deny'))
        self.assertIn('qubesair.Exec     * qubesair-console @tag:remote-zone ask', text)
        self.assertNotIn('qubesair.Exec     * qubesair-console @tag:remote-zone allow', text)

    def test_wildcards_injection_other_services_and_unlisted_sources_fail(self):
        baseline = {'source': 'qubesair-console', 'target': 'qa-closure', 'services': ['qubesair.Exec']}
        for changes in ({'target': '@anyvm'}, {'source': 'other-vm'},
                        {'target': 'test\n* * @anyvm @anyvm allow'},
                        {'services': ['*']}, {'services': ['qubes.VMShell']}, {'services': []}):
            with self.subTest(changes=changes):
                states = policy([{**baseline, **changes}])
                self.assertIn('grpc-scoped-grants-invalid', states)
                self.assertNotIn('grpc-csr-policy', states)

    def test_no_grants_retains_prompt(self):
        states = policy([])
        text = next(item['contents'] for item in states['grpc-csr-policy']['file.managed']
                    if 'contents' in item)
        self.assertNotIn('qubesair.Exec +', text)
        self.assertIn('@tag:remote-zone ask', text)


if __name__ == '__main__':
    unittest.main()
