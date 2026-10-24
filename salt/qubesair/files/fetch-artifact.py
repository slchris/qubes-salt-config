#!/usr/bin/python3
# SPDX-License-Identifier: MIT
"""Stage one pinned HTTPS payload in a fixed, root-owned cache for Salt.

No destination, trust override, command or timeout is accepted from the caller.
Salt still verifies the local cache digest and owns installation/service changes.
"""
import contextlib
import fcntl
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import signal
import ssl
import stat
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path('/rw/config/qubesair-artifacts')
OWNER = 0
KINDS = {'console', 'web', 'backup', 'issuer', 'endpoints', 'relay-call', 'relay-bootstrap'}
ATTEMPT_SECONDS = 120
SOCKET_SECONDS = 10
ATTEMPTS = 2
RETRY_SECONDS = 2
MAX_BYTES = 128 * 1024 * 1024
CHUNK_BYTES = 64 * 1024


class FetchError(Exception):
    """An unsafe request or payload must not replace the cached artifact."""


def safe_url(value):
    if not isinstance(value, str) or not value or len(value) > 8192:
        raise FetchError('invalid HTTPS URL')
    if re.search(r'[\s\x00-\x1f\x7f\\]', value):
        raise FetchError('invalid HTTPS URL')
    try:
        parsed = urllib.parse.urlsplit(value)
        if (parsed.scheme != 'https' or not parsed.hostname or parsed.username is not None
                or parsed.password is not None or parsed.fragment or parsed.port == 0):
            raise ValueError('URL shape')
    except ValueError as error:
        raise FetchError('invalid HTTPS URL') from error
    return value


class HTTPSRedirect(urllib.request.HTTPRedirectHandler):
    max_redirections = 5
    max_repeats = 1

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return super().redirect_request(req, fp, code, msg, headers, safe_url(newurl))


def trusted(info, directory=False):
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    if (not kind(info.st_mode) or info.st_uid != OWNER or info.st_mode & 0o022
            or (not directory and info.st_nlink != 1)):
        raise FetchError('artifact storage must be owned by root and not writable by other users')


def check_layout():
    for path in (*reversed(ROOT.parents), ROOT, ROOT / 'requests', ROOT / 'cache'):
        trusted(path.lstat(), directory=True)


@contextlib.contextmanager
def open_trusted(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        trusted(os.fstat(fd))
        with os.fdopen(fd, 'rb', closefd=False) as stream:
            yield stream
    finally:
        os.close(fd)


def request_for(kind):
    with open_trusted(ROOT / 'requests' / (kind + '.json')) as stream:
        payload = stream.read(16385)
    if len(payload) > 16384:
        raise FetchError('artifact request exceeds size limit')
    data = json.loads(payload)
    if (not isinstance(data, dict) or set(data) != {'url', 'sha256'}
            or not isinstance(data['sha256'], str)
            or not re.fullmatch('[a-f0-9]{64}', data['sha256'])):
        raise FetchError('artifact request requires an HTTPS URL and SHA256')
    safe_url(data['url'])
    return data


def cached_digest(path):
    try:
        with open_trusted(path) as stream:
            if os.fstat(stream.fileno()).st_size > MAX_BYTES:
                raise FetchError('cached artifact exceeds size limit')
            digest = hashlib.sha256()
            while chunk := stream.read(CHUNK_BYTES):
                digest.update(chunk)
            return digest.hexdigest()
    except FileNotFoundError:
        return None


def expired(_signum, _frame):
    raise TimeoutError('artifact attempt exceeded total time budget')


def interrupted(_signum, _frame):
    raise FetchError('artifact staging interrupted')


@contextlib.contextmanager
def attempt_deadline():
    previous = signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, ATTEMPT_SECONDS)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


def transfer(url, stream):
    # HTTPS is verified with the system trust store. Environment proxy settings
    # cannot change this deployment path, and redirects cannot downgrade TLS.
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}), HTTPSRedirect(),
        urllib.request.HTTPSHandler(context=ssl.create_default_context()))
    with opener.open(safe_url(url), timeout=SOCKET_SECONDS) as response:
        if response.status != 200:
            raise FetchError('artifact response must be HTTP 200')
        length = response.headers.get('Content-Length')
        if length is not None and (not length.isdigit() or not 0 < int(length) <= MAX_BYTES):
            raise FetchError('artifact Content-Length outside size limit')
        size, digest = 0, hashlib.sha256()
        while chunk := response.read(min(CHUNK_BYTES, MAX_BYTES - size + 1)):
            size += len(chunk)
            if size > MAX_BYTES:
                raise FetchError('artifact exceeds size limit')
            stream.write(chunk)
            digest.update(chunk)
        if size == 0 or (length is not None and size != int(length)):
            raise OSError('artifact body is incomplete')
    return size, digest.hexdigest()


def download(request, target):
    last = None
    for attempt in range(1, ATTEMPTS + 1):
        fd, name = tempfile.mkstemp(prefix='.' + target.name + '-', dir=ROOT / 'cache')
        temporary = Path(name)
        try:
            with os.fdopen(fd, 'wb') as stream, attempt_deadline():
                size, digest = transfer(request['url'], stream)
                if digest != request['sha256']:
                    raise FetchError('artifact SHA256 mismatch')
                stream.flush()
                os.fsync(stream.fileno())
                os.fchmod(stream.fileno(), 0o644)
            os.replace(temporary, target)
            return {'changed': True, 'comment': 'HTTPS artifact verified and staged',
                    'bytes': size, 'attempts': attempt}
        except (OSError, urllib.error.URLError, http.client.HTTPException) as error:
            last = type(error).__name__
        finally:
            temporary.unlink(missing_ok=True)
        if attempt < ATTEMPTS:
            time.sleep(RETRY_SECONDS)
    raise FetchError('artifact download failed after bounded retries: ' + str(last))


def stage(kind):
    if kind not in KINDS:
        raise FetchError('unsupported artifact identifier')
    if os.geteuid() != OWNER:
        raise FetchError('artifact staging requires root')
    check_layout()
    fd = os.open(ROOT / (kind + '.lock'), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        trusted(os.fstat(fd))
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        request = request_for(kind)
        target = ROOT / 'cache' / kind
        if cached_digest(target) == request['sha256']:
            return {'changed': False, 'comment': 'Pinned artifact already staged', 'attempts': 0}
        return download(request, target)
    finally:
        os.close(fd)


def main():
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        if len(sys.argv) != 2:
            raise FetchError('expected one fixed artifact identifier')
        print(json.dumps(stage(sys.argv[1])))
        return 0
    except (FetchError, OSError, ValueError) as error:
        # Never print redirect URLs, response bodies or configuration contents.
        reason = str(error) if isinstance(error, FetchError) else type(error).__name__
        print('artifact staging refused: ' + reason, file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
