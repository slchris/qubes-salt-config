#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Apply a digest-checked Qubes Air overlay without replacing the Salt tree.

Only the fixed paths and nonsecret configuration keys below are writable. The
operator supplies qubesair-deployment.json in a deployment bundle, never in git.
Existing configuration values outside the overlay are preserved. Every old file
is saved before writing; a failed write rolls back the completed replacements.
"""
import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import pprint
import re
import shutil
import stat
import tempfile

STATES = {'qubesair/console.sls', 'qubesair/console-ingress.sls',
          'qubesair/console-ingress.top', 'qubesair/backup.sls',
          'qubesair/backup-mount.sls', 'qubesair/backup-mount.top',
          'qubesair/install.sls', 'mgmt/remotevm/grpc-policy.sls',
          'mgmt/remotevm/grpc-console.sls', 'mgmt/remotevm/grpc-csr-relay.sls',
          'mgmt/remotevm/files/qubesair.GrpcProxy', 'mgmt/remotevm/register.sls',
          'mgmt/remotevm/files/qubesair.ConnectTCP',
          'mgmt/remotevm/files/qubesair.ConnectDesktop',
          'mgmt/remotevm/files/qubesair.RegisterRemoteVM',
          'mgmt/remotevm/files/refresh-endpoints.py.jinja'}
RPC_ARTIFACTS = {'issue_bin', 'list_endpoints', 'relay_call', 'relay_bootstrap'}
KEYS = {'console_binary_source', 'console_binary_sha256', 'console_web_source',
        'console_web_sha256', 'agent_package_url', 'agent_package_sha256',
        'agent_package_version', 'provision_wait_seconds', 'backup', 'allow_gateway_ingress'}
BACKUP_KEYS = {'enabled', 'binary_source', 'binary_sha256', 'offhost_dir',
               'keep', 'schedule', 'run_at_boot', 'sshfs'}
SAFE_PATH = re.compile(r'(?:/[A-Za-z0-9_.-]+)+')
SAFE_NAME = re.compile(r'[A-Za-z0-9][A-Za-z0-9_.-]*')
DIGEST = re.compile(r'[a-f0-9]{64}')


def check_value(key, value):
    if key == 'backup':
        check_fields(value, BACKUP_KEYS)
    elif key == 'sshfs':
        check_fields(value, {'enabled', 'host', 'port', 'user', 'path'})
    elif key in {'enabled', 'run_at_boot', 'allow_gateway_ingress'}:
        if type(value) is not bool:
            raise ValueError('expected boolean: ' + key)
    elif key in {'keep', 'provision_wait_seconds', 'port'}:
        if type(value) is not int or not 1 <= value <= 65535:
            raise ValueError('invalid positive bound: ' + key)
    elif key.endswith('_sha256'):
        if not isinstance(value, str) or not DIGEST.fullmatch(value):
            raise ValueError('invalid SHA256: ' + key)
    elif key == 'agent_package_version':
        if not isinstance(value,str) or not re.fullmatch(r'[0-9][A-Za-z0-9.+~_-]*',value):
            raise ValueError('invalid Debian package version')
    elif key.endswith('_source') or key.endswith('_url'):
        if not isinstance(value, str) or not re.fullmatch(
                r'(?:salt://qubesair/files/|https?://[A-Za-z0-9.:-]+/)[A-Za-z0-9_./+-]+', value):
            raise ValueError('invalid artifact location: ' + key)
        if '..' in value.split('/'):
            raise ValueError('artifact traversal')
    elif key in {'path', 'offhost_dir'}:
        if not isinstance(value, str) or not SAFE_PATH.fullmatch(value) or '..' in value.split('/'):
            raise ValueError('invalid path: ' + key)
    elif key == 'schedule':
        if not isinstance(value, str) or not re.fullmatch(r'\*-\*-\* \d{2}:\d{2}:00', value):
            raise ValueError('invalid daily schedule')
    elif not isinstance(value, str) or not SAFE_NAME.fullmatch(value):
        raise ValueError('invalid identifier: ' + key)


def check_fields(values, allowed):
    if not isinstance(values, dict) or set(values) - allowed:
        raise ValueError('unsupported configuration keys')
    for key, value in values.items():
        check_value(key, value)


def merge(existing, patch):
    for key, value in patch.items():
        if isinstance(value, dict):
            if not isinstance(existing.get(key, {}), dict):
                raise ValueError('configuration shape changed: ' + key)
            existing[key] = merge(existing.get(key, {}), value)
        else:
            existing[key] = value
    return existing


def check_remote_patch(patch):
    if not isinstance(patch, dict) or set(patch) != {'grpc'} or not isinstance(patch['grpc'], dict) or set(patch['grpc']) != {'csr'}:
        raise ValueError('only scoped grants and pinned RPC artifacts may be updated')
    csr = patch['grpc']['csr']
    allowed = {'service_grants', 'desktop_grants'} | {
        p + suffix for p in RPC_ARTIFACTS for suffix in ('_source', '_sha256')}
    if not isinstance(csr, dict) or set(csr) - allowed:
        raise ValueError('only scoped grants and pinned RPC artifacts may be updated')
    for prefix in RPC_ARTIFACTS:
        source, digest = prefix + '_source', prefix + '_sha256'
        if source in csr or digest in csr:
            if source not in csr or digest not in csr:
                raise ValueError('RPC artifact source and digest must be supplied together')
            check_value(source, csr[source])
            check_value(digest, csr[digest])
    grants = csr.get('service_grants', [])
    if not isinstance(grants, list) or len(grants) > 32:
        raise ValueError('invalid scoped grants')
    for grant in grants:
        if not isinstance(grant, dict) or set(grant) != {'source', 'target', 'services'}:
            raise ValueError('invalid scoped grant keys')
        for name in (grant['source'], grant['target']):
            if not isinstance(name, str) or not re.fullmatch(r'[A-Za-z][A-Za-z0-9_.-]{0,30}', name):
                raise ValueError('scoped grants require exact VM names')
        services = grant['services']
        if not isinstance(services, list) or not services or set(services) - {'qubesair.Exec', 'qubesair.FileCopy'}:
            raise ValueError('scoped grants only permit Exec/FileCopy')
    check_desktop_grants(csr.get('desktop_grants', []))


def check_desktop_grants(grants):
    if not isinstance(grants, list) or len(grants) > 32:
        raise ValueError('invalid desktop grants')
    for grant in grants:
        if not isinstance(grant, dict) or set(grant) != {'source', 'target'}:
            raise ValueError('invalid desktop grant keys')
        for name in (grant['source'], grant['target']):
            if not isinstance(name, str) or not re.fullmatch(r'[A-Za-z][A-Za-z0-9_.-]{0,30}', name):
                raise ValueError('desktop grants require exact VM names')
        if not grant['target'].startswith('remote-') or len(grant['target']) <= 7:
            raise ValueError('desktop grants require a nonempty remote-* target')


def check_desktop_callers(remote):
    csr = remote.get('grpc', {}).get('csr', {})
    grants = csr.get('desktop_grants', [])
    if not grants:
        return
    callers = csr.get('allowed_callers', [remote.get('relay', 'mgmt-jump')])
    if not isinstance(callers, list) or any(grant['source'] not in callers for grant in grants):
        raise ValueError('desktop grant source is not an existing allowed caller')


def patch_config(text, patch, remote=None):
    check_fields(patch, KEYS)
    updates = {'qubesair': patch}
    if remote is not None:
        check_remote_patch(remote)
        updates['remotevm'] = remote
    start = re.search(r'{%-?\s*set cfg\s*=\s*', text)
    if start is None:
        raise ValueError('config.jinja does not contain a literal cfg')
    end = re.search(r'\s*-?%}', text[start.end():])
    if end is None:
        raise ValueError('cfg end not found')
    expression = text[start.end():start.end() + end.start()]
    tree = ast.parse(expression, mode='eval').body
    values = ast.literal_eval(tree)
    if not isinstance(tree, ast.Dict):
        raise ValueError('cfg must be a literal dictionary')
    lines = expression.encode().splitlines(keepends=True)
    replacements = []
    for section, changes in updates.items():
        if not isinstance(values.get(section), dict):
            raise ValueError('configuration shape changed: ' + section)
        merged = merge(values[section], changes)
        if section == 'remotevm' and 'desktop_grants' in changes['grpc']['csr']:
            check_desktop_callers(merged)
        node = next(v for k, v in zip(tree.keys, tree.values) if ast.literal_eval(k) == section)
        begin = sum(map(len, lines[:node.lineno - 1])) + node.col_offset
        finish = sum(map(len, lines[:node.end_lineno - 1])) + node.end_col_offset
        replacements.append((begin, finish, pprint.pformat(merged, sort_dicts=False, width=100).encode()))
    updated = expression.encode()
    for begin, finish, replacement in sorted(replacements, reverse=True):
        updated = updated[:begin] + replacement + updated[finish:]
    return text[:start.end()] + updated.decode() + text[start.end() + end.start():]


def contained_file(root, relative):
    path = root / relative
    if root.is_symlink() or path.resolve().is_relative_to(root.resolve()) is False:
        raise ValueError('path escapes deployment root')
    for component in (path, *path.parents):
        if component == root.parent:
            break
        if component.is_symlink():
            raise ValueError('symlink in deployment path')
    return path


def prepare(source, target):
    manifest = json.loads((source / 'qubesair-deployment.json').read_text())
    if not {'files', 'qubesair'} <= set(manifest) or set(manifest) - {'files', 'qubesair', 'remotevm'} or not isinstance(manifest['files'], dict):
        raise ValueError('invalid deployment manifest')
    writes = {}
    for name, digest in manifest['files'].items():
        artifact = re.fullmatch(r'qubesair/files/[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*', name)
        if name not in STATES and not artifact:
            raise ValueError('unsupported deployment file: ' + name)
        if not isinstance(digest, str) or not DIGEST.fullmatch(digest):
            raise ValueError('invalid file digest')
        origin = contained_file(source / 'salt', name)
        if not origin.is_file():
            raise ValueError('deployment input must be a regular file')
        payload = origin.read_bytes()
        if hashlib.sha256(payload).hexdigest() != digest:
            raise ValueError('digest mismatch: ' + name)
        writes[contained_file(target, name)] = payload
    config = contained_file(target, 'config.jinja')
    writes[config] = patch_config(config.read_text(), manifest['qubesair'], manifest.get('remotevm')).encode()
    return writes


def replace_file(path, content, mode):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.qubesair-update-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), mode)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def install(source, target, backups):
    writes = prepare(source, target)  # Validate everything before touching dom0.
    changed = {p: data for p, data in writes.items() if not p.exists() or p.read_bytes() != data}
    if not changed:
        print('Qubes Air overlay already installed; no changes')
        return
    backups.mkdir(mode=0o700,parents=True,exist_ok=True)
    backup = Path(tempfile.mkdtemp(prefix='qubesair-', dir=backups))
    old = {}
    for path in changed:
        old[path] = (path.read_bytes(), stat.S_IMODE(path.stat().st_mode)) if path.exists() else None
        if path.exists():
            saved = backup / path.relative_to(target)
            saved.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, saved)
    applied = []
    try:
        for path, data in changed.items():
            replace_file(path, data, old[path][1] if old[path] else 0o644)
            applied.append(path)
    except OSError:
        for path in reversed(applied):
            if old[path] is None:
                path.unlink()
            else:
                replace_file(path, *old[path])
        raise
    print(f'Qubes Air overlay: {len(changed)} files updated; previous files saved in {backup}')


if __name__ == '__main__':
    if os.geteuid() != 0:
        raise SystemExit('run the scoped installer as root in dom0')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='validate without writing')
    options = parser.parse_args()
    source_root = Path(__file__).resolve().parents[1]
    salt_root = Path('/srv/salt/slchris')
    if options.check:
        planned = prepare(source_root, salt_root)
        print(f'Qubes Air overlay validated: {len(planned)} candidate files, no writes')
    else:
        install(source_root, salt_root, Path('/var/backups'))
