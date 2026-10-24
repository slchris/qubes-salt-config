# SPDX-License-Identifier: MIT
"""Exercise the downloader against real TLS, including stalled response bodies."""
import fcntl
import hashlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import signal
import ssl
import stat
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
PAYLOAD = b'verified release bytes\x00\xff' * 20
SHA256 = hashlib.sha256(PAYLOAD).hexdigest()


def load():
    spec = importlib.util.spec_from_file_location('artifact_fetch', ROOT / 'salt/qubesair/files/fetch-artifact.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TLSHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        self.server.calls.append(self.path)
        if self.path in ('/redirect', '/loop', '/downgrade', '/wronghost'):
            target = {'/redirect': self.server.url + '/ok', '/loop': self.server.url + '/loop',
                      '/downgrade': 'http://localhost:9/forbidden',
                      '/wronghost': self.server.url.replace('localhost', '127.0.0.1') + '/ok'}[self.path]
            self.send_response(302)
            self.send_header('Location', target)
            self.end_headers()
            return
        if self.path == '/retry' and self.server.calls.count('/retry') == 1:
            self.send_error(503)
            return
        body = PAYLOAD if self.path != '/corrupt' else b'corrupt'
        self.send_response(206 if self.path == '/partial' else 200)
        if self.path not in ('/unannounced', '/empty'):
            length = len(body) + 10 if self.path in ('/truncated', '/oversized') else len(body)
            self.send_header('Content-Length', str(length))
        self.end_headers()
        try:
            if self.path == '/empty':
                return
            if self.path == '/stall':
                self.wfile.write(body[:3])
                self.wfile.flush()
                self.server.stop.wait(getattr(self.server, 'stall_seconds', 2))
            elif self.path == '/dribble':
                for byte in body:
                    self.wfile.write(bytes([byte]))
                    self.wfile.flush()
                    if self.server.stop.wait(0.02):
                        return
            else:
                self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass


class ArtifactFetchIOTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.certs = tempfile.TemporaryDirectory()
        directory = Path(cls.certs.name)
        cls.cert = directory / 'certificate.pem'
        key = directory / 'private.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                        '-keyout', str(key), '-out', str(cls.cert), '-subj', '/CN=localhost',
                        '-addext', 'subjectAltName=DNS:localhost'], check=True, capture_output=True)
        cls.server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        cls.server_context.load_cert_chain(cls.cert, key)
        cls.valid_context = ssl.create_default_context(cafile=str(cls.cert))
        cls.untrusted_context = ssl.create_default_context()

    @classmethod
    def tearDownClass(cls):
        cls.certs.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'cache').mkdir()
        (self.root / 'requests').mkdir()
        self.module = load()
        self.module.ROOT = self.root
        self.module.OWNER = os.geteuid()
        self.module.ATTEMPT_SECONDS = 1
        self.module.SOCKET_SECONDS = 0.2
        self.module.RETRY_SECONDS = 0
        self.module.MAX_BYTES = 1024
        self.target = self.root / 'cache' / 'console'
        self.target.write_bytes(b'previous pinned cache')
        self.target.chmod(0o644)
        self.previous = self.target.read_bytes()
        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), TLSHandler)
        self.server.daemon_threads = True
        self.server.socket = self.server_context.wrap_socket(self.server.socket, server_side=True)
        self.server.url = 'https://localhost:' + str(self.server.server_address[1])
        self.server.calls = []
        self.server.stop = threading.Event()
        worker = threading.Thread(target=self.server.serve_forever, kwargs={'poll_interval': 0.02}, daemon=True)
        worker.start()
        self.addCleanup(self.stop_server, worker)
        self.context = mock.patch.object(self.module.ssl, 'create_default_context', return_value=self.valid_context)
        self.context.start()
        self.addCleanup(self.context.stop)

    def stop_server(self, worker):
        self.server.stop.set()
        self.server.shutdown()
        self.server.server_close()
        worker.join(timeout=2)
        self.assertFalse(worker.is_alive())

    def request(self, path='/ok'):
        return {'url': self.server.url + path, 'sha256': SHA256}

    def fetch(self, path='/ok'):
        return self.module.download(self.request(path), self.target)

    def assert_preserved(self):
        self.assertEqual(self.target.read_bytes(), self.previous)
        self.assertEqual(list((self.root / 'cache').iterdir()), [self.target])

    def write_request(self, request=None):
        path = self.root / 'requests/console.json'
        path.write_text(json.dumps(request or self.request()))
        path.chmod(0o644)
        return path

    def fixture_layout(self):
        # The harness lives under an OS temporary directory. Production checks
        # every ancestor; exercise those separately below and in Linux smoke.
        for directory in (self.root, self.root / 'requests', self.root / 'cache'):
            self.module.trusted(directory.lstat(), directory=True)

    def test_real_https_redirect_replacement_and_idempotent_reapply(self):
        result = self.fetch('/redirect')
        self.assertTrue(result['changed'])
        self.assertEqual(result['attempts'], 1)
        self.assertEqual(self.server.calls, ['/redirect', '/ok'])
        self.assertEqual(self.target.read_bytes(), PAYLOAD)
        self.assertEqual(stat.S_IMODE(self.target.stat().st_mode), 0o644)
        self.write_request()
        with mock.patch.object(self.module, 'check_layout', side_effect=self.fixture_layout):
            self.assertFalse(self.module.stage('console')['changed'])
        self.assertEqual(self.server.calls, ['/redirect', '/ok'], 'reapply must not download')

    def test_transient_http_failure_retries_from_a_fresh_file(self):
        result = self.fetch('/retry')
        self.assertEqual(result['attempts'], 2)
        self.assertEqual(self.server.calls, ['/retry', '/retry'])
        self.assertEqual(self.target.read_bytes(), PAYLOAD)
        self.assertEqual(list((self.root / 'cache').iterdir()), [self.target])

    def test_stall_exhausts_socket_budget_and_preserves_existing_cache(self):
        started = time.monotonic()
        with self.assertRaises(self.module.FetchError):
            self.fetch('/stall')
        self.assertLess(time.monotonic() - started, 1.5)
        self.assertEqual(self.server.calls, ['/stall', '/stall'])
        self.assert_preserved()

    def test_slow_continuous_body_cannot_evade_total_deadline(self):
        self.module.ATTEMPT_SECONDS = 0.15
        self.module.SOCKET_SECONDS = 1
        started = time.monotonic()
        with self.assertRaises(self.module.FetchError):
            self.fetch('/dribble')
        self.assertLess(time.monotonic() - started, 1.0)
        self.assertEqual(self.server.calls, ['/dribble', '/dribble'])
        self.assert_preserved()

    def test_bad_digest_incomplete_empty_or_partial_body_cannot_replace(self):
        for path in ('/corrupt', '/truncated', '/empty', '/partial'):
            with self.subTest(path=path), self.assertRaises(self.module.FetchError):
                self.fetch(path)
            self.assert_preserved()
        self.assertEqual(self.server.calls.count('/corrupt'), 1, 'bad digest is not transient')

    def test_size_limit_with_and_without_content_length_and_exact_boundary(self):
        self.module.MAX_BYTES = len(PAYLOAD) - 1
        for path in ('/oversized', '/unannounced'):
            with self.subTest(path=path), self.assertRaises(self.module.FetchError):
                self.fetch(path)
            self.assert_preserved()
        self.module.MAX_BYTES = len(PAYLOAD)
        self.assertEqual(self.fetch()['bytes'], len(PAYLOAD))

    def test_redirect_loop_downgrade_and_wrong_host_are_rejected(self):
        for path in ('/loop', '/downgrade', '/wronghost'):
            with self.subTest(path=path), self.assertRaises(self.module.FetchError):
                self.fetch(path)
            self.assert_preserved()
        self.assertNotIn('/ok', self.server.calls, 'wrong-host TLS must fail before an HTTP request')

    def test_wrong_ca_is_rejected_before_request(self):
        with mock.patch.object(self.module.ssl, 'create_default_context', return_value=self.untrusted_context):
            with self.assertRaises(self.module.FetchError):
                self.fetch()
        self.assertEqual(self.server.calls, [])
        self.assert_preserved()

    def test_unsafe_urls_and_unpinned_requests_are_rejected(self):
        for value in ('http://example.test/file', 'file:///etc/passwd', 'https://user:pass@example.test/a',
                      'https://example.test/a#fragment', 'https://example.test/a\nheader',
                      'https://example.test:0/a', 'https://example.test:99999/a', 'https://\\host/a',
                      'https:///missing', '', None):
            with self.subTest(url=value), self.assertRaises(self.module.FetchError):
                self.module.safe_url(value)
        for request in ({'url': self.server.url}, {**self.request(), 'sha256': 'BAD'},
                        {**self.request(), 'destination': '/etc/passwd'}):
            self.write_request(request)
            with self.assertRaises(self.module.FetchError):
                self.module.request_for('console')
        self.write_request().write_bytes(b'x' * 16385)
        with self.assertRaises(self.module.FetchError):
            self.module.request_for('console')
        self.assertEqual(self.server.calls, [])
        self.assert_preserved()

    def test_unknown_identifier_and_unprivileged_caller_fail_before_io(self):
        for kind in ('', '../console', '/tmp/console', 'console;id', 'new-artifact'):
            with self.subTest(kind=kind), self.assertRaises(self.module.FetchError):
                self.module.stage(kind)
        with mock.patch.object(self.module.os, 'geteuid', return_value=self.module.OWNER + 1):
            with self.assertRaises(self.module.FetchError):
                self.module.stage('console')
        self.assertEqual(self.server.calls, [])

    def test_symlink_fifo_hardlink_or_writable_cache_is_refused(self):
        original = self.root / 'untouched'
        original.write_bytes(self.previous)
        self.target.unlink()
        self.target.symlink_to(original)
        with self.assertRaises(OSError):
            self.module.cached_digest(self.target)
        self.target.unlink()
        os.mkfifo(self.target)
        with self.assertRaises(self.module.FetchError):
            self.module.cached_digest(self.target)
        self.target.unlink()
        os.link(original, self.target)
        with self.assertRaises(self.module.FetchError):
            self.module.cached_digest(self.target)
        self.target.unlink()
        self.target.write_bytes(self.previous)
        self.target.chmod(0o666)
        with self.assertRaises(self.module.FetchError):
            self.module.cached_digest(self.target)
        self.assertEqual(original.read_bytes(), self.previous)

    def test_request_symlink_and_untrusted_ancestor_fail_closed(self):
        outside = self.root / 'outside.json'
        outside.write_text(json.dumps(self.request()))
        (self.root / 'requests/console.json').symlink_to(outside)
        with self.assertRaises(OSError):
            self.module.request_for('console')
        for mode, owner in ((stat.S_IFLNK | 0o777, self.module.OWNER),
                            (stat.S_IFDIR | 0o777, self.module.OWNER),
                            (stat.S_IFDIR | 0o755, self.module.OWNER + 1)):
            def info(path):
                bad = path == self.root.parent
                return types.SimpleNamespace(st_mode=mode if bad else stat.S_IFDIR | 0o755,
                                             st_uid=owner if bad else self.module.OWNER, st_nlink=1)
            with self.subTest(mode=mode, owner=owner), mock.patch.object(Path, 'lstat', info):
                with self.assertRaises(self.module.FetchError):
                    self.module.check_layout()

    def test_concurrent_stage_fails_without_duplicate_download(self):
        self.write_request()
        with (self.root / 'console.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with mock.patch.object(self.module, 'check_layout', side_effect=self.fixture_layout):
                with self.assertRaises(BlockingIOError):
                    self.module.stage('console')
        self.assertEqual(self.server.calls, [])
        self.assert_preserved()

    def test_failed_atomic_publish_preserves_prior_file_and_cleans_partials(self):
        with mock.patch.object(self.module.os, 'replace', side_effect=OSError('publish denied')):
            with self.assertRaises(self.module.FetchError):
                self.fetch()
        self.assert_preserved()

    def test_sigterm_cleans_partial_and_does_not_retry(self):
        self.write_request(self.request('/stall'))
        script = '''import importlib.util,os,sys,ssl
from pathlib import Path
spec=importlib.util.spec_from_file_location('fetch',sys.argv[1])
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
m.ROOT=Path(sys.argv[2]);m.OWNER=os.geteuid()
m.check_layout=lambda: [m.trusted(p.lstat(),directory=True) for p in (m.ROOT,m.ROOT/'requests',m.ROOT/'cache')]
ctx=ssl.create_default_context(cafile=sys.argv[3]);m.ssl.create_default_context=lambda:ctx
m.SOCKET_SECONDS=5;m.ATTEMPT_SECONDS=5
sys.argv=['fetch.py','console'];sys.exit(m.main())
'''
        child = subprocess.Popen([sys.executable, '-c', script,
                                  str(ROOT / 'salt/qubesair/files/fetch-artifact.py'),
                                  str(self.root), str(self.cert)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            limit = time.monotonic() + 3
            while '/stall' not in self.server.calls and time.monotonic() < limit:
                time.sleep(0.01)
            self.assertIn('/stall', self.server.calls)
            child.send_signal(signal.SIGTERM)
            output, error = child.communicate(timeout=2)
            self.assertEqual(child.returncode, 1, error)
            self.assertEqual(output, b'')
            self.assertIn(b'interrupted', error)
            self.assertEqual(self.server.calls, ['/stall'])
            self.assert_preserved()
        finally:
            if child.poll() is None:
                child.kill()
                child.communicate(timeout=2)


if __name__ == '__main__':
    unittest.main()
