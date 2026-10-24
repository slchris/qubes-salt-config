#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Run only in a fresh offline Linux container as root; creates the fixed cache."""
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import threading
import time

from test_artifact_fetch_io import ArtifactFetchIOTests, PAYLOAD, ROOT, SHA256, TLSHandler


def main():
    cache_root = Path('/rw/config/qubesair-artifacts')
    if sys.platform != 'linux' or os.geteuid() != 0 or not Path('/.dockerenv').exists() or cache_root.exists():
        raise RuntimeError('requires a fresh root Linux container with no artifact cache')
    for path in (cache_root / 'requests', cache_root / 'cache'):
        path.mkdir(parents=True, mode=0o755)
    helper = cache_root / 'fetch.py'
    source = ROOT / 'salt/qubesair/files/fetch-artifact.py'
    shutil.copyfile(source, helper)
    helper.chmod(0o644)
    assert helper.read_bytes() == source.read_bytes()
    ArtifactFetchIOTests.setUpClass()
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), TLSHandler)
    server.socket = ArtifactFetchIOTests.server_context.wrap_socket(server.socket, server_side=True)
    server.daemon_threads = True
    server.url = 'https://localhost:' + str(server.server_address[1])
    server.calls = []
    server.stop = threading.Event()
    server.stall_seconds = 15
    worker = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': 0.02}, daemon=True)
    worker.start()
    env = {**os.environ, 'SSL_CERT_FILE': str(ArtifactFetchIOTests.cert)}
    request = cache_root / 'requests/console.json'
    target = cache_root / 'cache/console'

    def configure(path, digest=SHA256):
        request.write_text(json.dumps({'url': server.url + path, 'sha256': digest}))
        request.chmod(0o644)

    def run(success, **options):
        result = subprocess.run(['/usr/bin/python3', str(helper), 'console'],
                                env=env, capture_output=True, text=True, timeout=30, **options)
        assert (result.returncode == 0) == success, result.stderr
        return json.loads(result.stdout) if success else result.stderr

    try:
        configure('/redirect')
        assert run(True)['changed']
        assert target.read_bytes() == PAYLOAD
        assert not run(True)['changed']
        calls = len(server.calls)
        configure('/corrupt', 'a' * 64)
        assert 'SHA256 mismatch' in run(False)
        assert hashlib.sha256(target.read_bytes()).hexdigest() == SHA256
        assert len(server.calls) == calls + 1
        calls = len(server.calls)
        configure('/ok', 'b' * 64)
        assert 'requires root' in run(False, user=65534)
        assert len(server.calls) == calls
        real = request.with_suffix('.saved')
        request.rename(real)
        request.symlink_to(real)
        run(False)
        request.unlink()
        real.rename(request)
        assert len(server.calls) == calls
        configure('/stall', 'c' * 64)
        started = time.monotonic()
        assert 'bounded retries' in run(False)
        elapsed = time.monotonic() - started
        assert 20 <= elapsed < 28, elapsed
        assert server.calls.count('/stall') == 2
        assert hashlib.sha256(target.read_bytes()).hexdigest() == SHA256
        assert list((cache_root / 'cache').iterdir()) == [target]
        print(json.dumps({'unmodified_helper': True, 'root_paths_and_tls_verified': True,
                          'redirect_and_idempotence': True, 'unprivileged_and_symlink_refused': True,
                          'bad_digest_preserved_cache': True, 'default_stall_seconds': round(elapsed, 2),
                          'attempts': 2, 'partial_files': 0}))
    finally:
        server.stop.set()
        server.shutdown()
        server.server_close()
        worker.join(timeout=2)
        ArtifactFetchIOTests.tearDownClass()


if __name__ == '__main__':
    main()
