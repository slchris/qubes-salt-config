# SPDX-License-Identifier: MIT
"""Check rendered fixtures with Qubes' real parser; never execute an RPC."""
import json
import sys
import uuid

from qrexec.policy import parser


def main():
    fixtures = json.load(sys.stdin)
    domains = {}
    for name in ('work-client', 'other-client', 'test-relay', 'other-relay',
                 'remote-qa', 'remote-other', 'qubesair-console'):
        domains[name] = {'name': name, 'type': 'AppVM', 'power_state': 'Running',
                         'tags': ['remote-zone'] if name.startswith('remote-') else [],
                         'uuid': str(uuid.uuid5(uuid.NAMESPACE_DNS, name)),
                         'icon': 'appvm-gray', 'default_dispvm': None, 'guivm': None}
    cases = [
        ('+remote-qa', 'work-client', 'test-relay', 'Allow'),
        ('+remote-other', 'work-client', 'test-relay', 'Deny'),
        ('+', 'work-client', 'test-relay', 'Deny'),
        ('+remote-qa+10005', 'work-client', 'test-relay', 'Deny'),
        ('+remote-qa', 'other-client', 'test-relay', 'Deny'),
        ('+remote-qa', 'work-client', 'other-relay', 'Deny'),
        ('+remote-qa', 'work-client', 'remote-qa', 'Deny'),
    ]
    count = 0
    for variant in ('granted', 'denied'):
        policy = parser.StringPolicy(policy=fixtures[variant])
        for argument, source, target, expected in cases:
            request = parser.Request('qubesair.ConnectDesktop', argument, source, target,
                                     system_info={'domains': domains})
            rule = policy.find_matching_rule(request)
            actual = type(rule.action).__name__
            wanted = expected if variant == 'granted' else 'Deny'
            assert actual == wanted, (variant, argument, source, target, actual, wanted)
            count += 1
    print(f'Qubes policy parser: {count} exact grant/default deny checks passed; no RPC executed')


if __name__ == '__main__':
    main()
