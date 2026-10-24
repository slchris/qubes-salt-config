#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Exercise real Salt requisites in a fresh offline Linux container with Salt."""
import hashlib
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading

from test_artifact_fetch_io import ArtifactFetchIOTests, ROOT, SHA256, TLSHandler


def main():
    cache = Path('/rw/config/qubesair-artifacts/cache/console')
    if sys.platform != 'linux' or os.geteuid() != 0 or not Path('/.dockerenv').exists() or cache.parent.parent.exists():
        raise RuntimeError('requires a fresh root Linux container with Salt and no artifact cache')
    Path('/rw/config').mkdir(parents=True, mode=0o755)
    ArtifactFetchIOTests.setUpClass()
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), TLSHandler)
    server.socket = ArtifactFetchIOTests.server_context.wrap_socket(server.socket, server_side=True)
    server.daemon_threads = True
    server.url = 'https://localhost:' + str(server.server_address[1])
    server.calls = []
    server.stop = threading.Event()
    worker = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': 0.02}, daemon=True)
    worker.start()
    env = {**os.environ, 'SSL_CERT_FILE': str(ArtifactFetchIOTests.cert)}
    try:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            states = root / 'states'
            states.mkdir()
            config = root / 'config'
            config.mkdir()
            target = root / 'installed'
            (config / 'minion').write_text('file_client: local\nfile_roots:\n  base:\n'
                                          f'    - {states}\n    - {ROOT / "salt"}\n'
                                          f'cachedir: {root / "cache"}\npki_dir: {root / "pki"}\n'
                                          f'sock_dir: {root / "sock"}\n')

            def configure(path, digest=SHA256):
                source = server.url + path
                cfg = {'qubesair': {'enabled': True, 'qube': socket.gethostname(),
                                   'console_binary_source': source, 'console_binary_sha256': digest}}
                (states / 'config.jinja').write_text('{% set cfg = ' + repr(cfg) + ' %}')
                template = "{% from 'qubesair/macros/artifacts.jinja' import stage, local_source %}\n"
                template += 'include:\n  - qubesair.artifact-fetch\n'
                template += "{{ stage('console', '" + source + "', '" + digest + "', ['installed']) }}\n"
                template += 'installed:\n  file.managed:\n    - name: ' + str(target) + '\n'
                template += "    - source: {{ local_source('console', '" + source + "') }}\n"
                template += '    - source_hash: sha256=' + digest + "\n    - mode: '0644'\n"
                (states / 'fixture.sls').write_text(template)

            def apply(preview=False, success=True, state='fixture'):
                command = ['salt-call', '--local', '--config-dir', str(config), '--out=json',
                           '--retcode-passthrough', '--log-level=error', 'state.apply', state]
                if preview:
                    command.append('test=True')
                result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=60)
                assert result.stdout.lstrip().startswith('{'), (result.returncode, result.stdout, result.stderr)
                data = json.loads(result.stdout)['local']
                assert isinstance(data, dict), data
                failures = [value for value in data.values() if value['result'] is False]
                assert (not failures and result.returncode == 0) == success, (result.stderr, data)
                return data

            configure('/redirect')
            prefetched = apply(state='qubesair.artifact-prefetch')
            assert not target.exists() and cache.exists()
            calls = len(server.calls)
            first_preview = apply(preview=True)
            assert not target.exists() and len(server.calls) == calls
            applied = apply()
            assert hashlib.sha256(target.read_bytes()).hexdigest() == SHA256
            calls = len(server.calls)
            repeated = apply()
            assert not any(value['changes'] for value in repeated.values()), repeated
            assert len(server.calls) == calls
            target.unlink()
            cache.unlink()
            apply()
            assert hashlib.sha256(target.read_bytes()).hexdigest() == SHA256
            configure('/corrupt', 'b' * 64)
            apply(success=False)
            assert hashlib.sha256(target.read_bytes()).hexdigest() == SHA256
            assert hashlib.sha256(cache.read_bytes()).hexdigest() == SHA256
            assert not list(cache.parent.glob('.console-*'))
            print(json.dumps({'salt_version': subprocess.check_output(['salt-call', '--version'], text=True).strip(),
                              'prefetch_states': len(prefetched), 'preview_states': len(first_preview),
                              'preview_network_requests': 0, 'direct_empty_cache_apply': True,
                              'applied_states': len(applied), 'repeat_changes': 0,
                              'failed_fetch_preserved_live_file': True, 'partial_files': 0}))
    finally:
        server.stop.set()
        server.shutdown()
        server.server_close()
        worker.join(timeout=2)
        ArtifactFetchIOTests.tearDownClass()


if __name__ == '__main__':
    main()
