#!/usr/bin/python3
# SPDX-License-Identifier: MIT
"""Restore only the opt-in Console port from this Qube's upstream gateway.

This root helper has no arguments, configurable commands or write paths. Its
root-owned config and QubesDB are trusted deployment inputs; nft transactions
touch only rules carrying our reserved comment in ip/qubes/custom-input.
"""
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time

ROOT = Path('/rw/config/qubesair-ingress')
TAG = 'qubesair-console-ingress'
NFT = '/usr/sbin/nft'
QDB = '/usr/bin/qubesdb-read'


def validate(config):
    if not isinstance(config, dict) or set(config) != {'enabled', 'qube', 'listen'}:
        raise ValueError('invalid ingress configuration keys')
    if type(config['enabled']) is not bool:
        raise ValueError('ingress enabled must be a boolean')
    if not isinstance(config['qube'], str) or not re.fullmatch(r'[A-Za-z][A-Za-z0-9_.-]{0,30}', config['qube']):
        raise ValueError('ingress requires an exact Qube name')
    listen = config['listen']
    if not isinstance(listen, str) or len(listen) > 80 or ':' not in listen:
        raise ValueError('invalid Console listen address')
    host, port = listen.rsplit(':', 1)
    if not re.fullmatch(r'[0-9]{1,5}', port) or not 1024 <= int(port) <= 65535:
        raise ValueError('invalid Console listen port')
    address = ipaddress.ip_address(host.strip('[]'))
    if config['enabled'] and (address.version != 4 or address.is_loopback or address.is_multicast):
        raise ValueError('gateway ingress requires an IPv4 Console listener')
    return int(port)


def run(argv, body=None):
    result = subprocess.run(argv, input=body, text=True, capture_output=True, timeout=10, check=True)
    if len(result.stdout) > 262144:
        raise ValueError('oversized ingress command output')
    return result.stdout


def owned_rules(execute):
    snapshot = json.loads(execute([NFT, '-j', 'list', 'chain', 'ip', 'qubes', 'custom-input']))
    entries = snapshot.get('nftables') if isinstance(snapshot, dict) else None
    if not isinstance(entries, list) or len(entries) > 4096:
        raise ValueError('invalid nftables snapshot')
    owned = []
    for entry in entries:
        if not isinstance(entry, dict):
            raise ValueError('invalid nftables entry')
        rule = entry.get('rule', {})
        if not isinstance(rule, dict) or rule.get('comment') != TAG:
            continue
        if (rule.get('family'), rule.get('table'), rule.get('chain')) != ('ip', 'qubes', 'custom-input'):
            raise ValueError('ingress rule outside fixed chain')
        if type(rule.get('handle')) is not int or not 0 < rule['handle'] < 2**64:
            raise ValueError('invalid ingress rule handle')
        owned.append(rule)
    if len(owned) > 8:
        raise ValueError('too many ingress rules')
    return owned


def matches(rule, gateway, port):
    expr = rule.get('expr')
    if not isinstance(expr, list) or len(expr) != 4 or expr[-1] != {'accept': None}:
        return False
    expected = [({'payload': {'protocol': 'ip', 'field': 'saddr'}}, gateway),
                ({'payload': {'protocol': 'tcp', 'field': 'dport'}}, port)]
    for expression, (left, right) in zip(expr[:2], expected):
        if expression != {'match': {'op': '==', 'left': left, 'right': right}}:
            return False
    state = expr[2].get('match', {}) if isinstance(expr[2], dict) else {}
    states = state.get('right')
    return (state.get('op') == 'in' and state.get('left') == {'ct': {'key': 'state'}}
            and isinstance(states, list) and all(isinstance(s, str) for s in states)
            and sorted(states) == ['established', 'new', 'related'])


def apply(config, execute=run):
    port = validate(config)
    if execute([QDB, '/name']).strip() != config['qube']:
        raise ValueError('ingress Qube identity mismatch')
    gateway = None
    if config['enabled']:
        gateway = ipaddress.IPv4Address(execute([QDB, '/qubes-gateway']).strip())
        if gateway.is_unspecified or gateway.is_multicast or gateway.is_loopback or gateway == ipaddress.IPv4Address('255.255.255.255'):
            raise ValueError('invalid Qubes gateway')
        gateway = str(gateway)
    rules = owned_rules(execute)
    if (not config['enabled'] and not rules) or (len(rules) == 1 and gateway and matches(rules[0], gateway, port)):
        return False
    commands = ['delete rule ip qubes custom-input handle ' + str(r['handle']) for r in rules]
    if gateway:
        commands.append('add rule ip qubes custom-input ip saddr ' + gateway + ' tcp dport ' + str(port)
                        + ' ct state { new, established, related } accept comment "' + TAG + '"')
    # A single nft transaction preserves unrelated rules and never leaves a gap
    # between removing the previous gateway/port and installing the new one.
    execute([NFT, '-f', '-'], '\n'.join(commands) + '\n')
    observed = owned_rules(execute)
    if (gateway and (len(observed) != 1 or not matches(observed[0], gateway, port))) or (not gateway and observed):
        raise ValueError('ingress verification failed')
    return True


def root_file(name, flags):
    fd = os.open(ROOT / name, flags | os.O_NOFOLLOW, 0o600)
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
        os.close(fd)
        raise ValueError('ingress file must be root-owned and not writable by others')
    return fd


def acquire_lock(fd):
    deadline = time.monotonic() + 10
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        except BlockingIOError:
            if time.monotonic() >= deadline:
                raise TimeoutError('ingress lock timeout')
            time.sleep(0.05)


def main():
    if len(sys.argv) != 1 or os.geteuid() != 0:
        raise ValueError('ingress helper requires root and accepts no arguments')
    info = ROOT.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
        raise ValueError('untrusted ingress directory')
    lock = root_file('apply.lock', os.O_CREAT | os.O_RDWR)
    try:
        acquire_lock(lock)
        with os.fdopen(root_file('config.json', os.O_RDONLY)) as source:
            text = source.read(4097)
        if len(text) > 4096:
            raise ValueError('oversized ingress configuration')
        changed = apply(json.loads(text))
        print(json.dumps({'changed': changed, 'comment': 'Console gateway ingress verified'}))
    finally:
        os.close(lock)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print('Console ingress failed: ' + str(error), file=sys.stderr)
        raise SystemExit(1) from error
