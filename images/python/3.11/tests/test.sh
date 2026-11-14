#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
recipe=$(dirname "$0")/../melange.yaml
version=$(sed -n 's/^  version: "\([0-9.]*\)".*/\1/p' "$recipe")
[ -n "$version" ] || { echo "FAIL: no package.version in $recipe" >&2; exit 1; }

failures=0
user=

# check NAME: run the Python program on stdin in the image; it must exit 0.
check() {
  if docker run --rm -i --network none ${user:+--user "$user"} "$image" - >"$tmp" 2>&1; then
    echo "PASS: $1"
  else
    echo "FAIL: $1" >&2
    sed 's/^/  /' "$tmp" >&2
    failures=$((failures + 1))
  fi
}

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

check "interpreter is CPython $version" <<EOF
import platform, sys
assert platform.python_implementation() == 'CPython', platform.python_implementation()
assert platform.python_version() == '$version', platform.python_version()
EOF

check "stdlib extension modules load" <<'EOF'
import _bz2, _ctypes, _curses, _decimal, _hashlib, _lzma, _sqlite3, _ssl, pyexpat, readline, zlib
import hashlib, ssl, sqlite3
assert ssl.OPENSSL_VERSION.startswith('OpenSSL '), ssl.OPENSSL_VERSION
assert hashlib.sha256(b'abc').hexdigest().startswith('ba7816bf')
db = sqlite3.connect(':memory:')
assert db.execute('select 1 + 1').fetchone() == (2,)
EOF

check "ssl verifies against the CA bundle" <<'EOF'
import ssl
ctx = ssl.create_default_context()
assert ctx.verify_mode == ssl.CERT_REQUIRED
assert ctx.cert_store_stats()['x509_ca'] > 0, ctx.cert_store_stats()
EOF

check "venv installs the bundled pip wheel" <<'EOF'
import subprocess, sys, tempfile
with tempfile.TemporaryDirectory() as d:
    subprocess.run([sys.executable, '-m', 'venv', d], check=True)
    out = subprocess.run([d + '/bin/python', '-m', 'pip', '--version'], check=True,
                         capture_output=True, text=True).stdout
    assert out.startswith('pip '), out
EOF

# Regression checks for the security patches in this directory. Each one
# fails on a build without the patch.

check "CVE-2025-15366: imaplib rejects NUL, CR and LF in commands" <<'EOF'
import imaplib, socket, threading
client_sock, server_sock = socket.socketpair()
client_sock.settimeout(5)

def serve():
    f = server_sock.makefile('rwb')
    f.write(b'* PREAUTH ready\r\n')
    f.flush()
    for line in f:
        tag = line.split(b' ', 1)[0]
        if b'CAPABILITY' in line:
            f.write(b'* CAPABILITY IMAP4rev1\r\n')
        f.write(tag + b' OK done\r\n')
        f.flush()

threading.Thread(target=serve, daemon=True).start()

class Client(imaplib.IMAP4):
    def open(self, host='', port=imaplib.IMAP4_PORT, timeout=None):
        self.host, self.port, self.sock = host, port, client_sock
        self.file = client_sock.makefile('rb')

client = Client()
for c in '\0\r\n':
    try:
        typ, data = client.select('INBOX' + c + 'x')
    except ValueError as e:
        assert 'not allowed' in str(e), e
    else:
        raise AssertionError(f'select() sent {c!r} in a command: {typ} {data}')
EOF

check "CVE-2025-15367: poplib rejects control characters in commands" <<'EOF'
import poplib, socket
client_sock, server_sock = socket.socketpair()
client_sock.settimeout(5)
server_sock.sendall(b'+OK ready\r\n+OK\r\n+OK\r\n')
pop = poplib.POP3.__new__(poplib.POP3)
pop._debugging, pop.encoding, pop.sock = 0, 'UTF-8', client_sock
pop.file = client_sock.makefile('rb')
pop.welcome = pop._getresp()
try:
    resp = pop.user('alice\r\nDELE 1')
except ValueError as e:
    assert 'Control characters' in str(e), e
else:
    raise AssertionError(f'user() sent CR/LF in a command: {resp}')
EOF

check "CVE-2026-6019: Morsel.js_output() does not embed raw cookie markup" <<'EOF'
from http.cookies import Morsel
m = Morsel()
m.set('k', 'v', '</script><script>alert(1)</script>')
out = m.js_output()
assert '<script>alert' not in out, out
assert 'atob(' in out, out
EOF

check "CVE-2026-3446: base64 decodes data after the first padded quad" <<'EOF'
import base64, binascii
assert base64.b64decode(b'ab==cd') == b'i\xb7\x1d', base64.b64decode(b'ab==cd')
assert binascii.a2b_base64(b'abc=d') == b'i\xb7\x1d', binascii.a2b_base64(b'abc=d')
try:
    base64.b64decode(b'ab==cd', validate=True)
except binascii.Error:
    pass
else:
    raise AssertionError('strict decoding accepted excess data')
EOF

check "CVE-2026-103995: http.client rejects malformed Content-Length and chunk-size" <<'EOF'
import http.client, io

class Sock:
    def __init__(self, data):
        self.data = data
    def makefile(self, *args, **kwargs):
        return io.BytesIO(self.data)

def response(head, body):
    r = http.client.HTTPResponse(Sock(b'HTTP/1.1 200 OK\r\n' + head + b'\r\n' + body))
    r.begin()
    return r

# 3.11 already ignored a negative length; a sign, an underscore or a 0x
# prefix was still accepted by int().
for value in (b'+3', b'1_0', b'-3'):
    r = response(b'Content-Length: ' + value + b'\r\n', b'abcdefghijkl')
    assert r.length is None, (value, r.length)
assert response(b'Content-Length: 3 \r\n', b'abcdef').length == 3

r = response(b'Transfer-Encoding: chunked\r\n', b'0x3\r\nabc\r\n0\r\n\r\n')
try:
    body = r.read()
except http.client.IncompleteRead:
    pass
else:
    raise AssertionError(f'chunk-size 0x3 was accepted: {body!r}')
EOF

check "CVE-2026-116566: getaddrinfo rejects an embedded NUL" <<'EOF'
import socket
for host, port in ((b'127.0.0.1\x00.attacker.example', 80), ('127.0.0.1', '80\x00x')):
    try:
        res = socket.getaddrinfo(host, port, flags=socket.AI_NUMERICHOST)
    except ValueError as e:
        assert 'null characters' in str(e), e
    else:
        raise AssertionError(f'getaddrinfo({host!r}, {port!r}) truncated at NUL: {res[0][4]}')
EOF

# Upstream's test_cleanup_with_symlink_race (python/cpython#161944), which
# needs a non-root user: dir1 is swapped for a symlink to an outside
# directory while cleanup() recovers from a PermissionError, and the outside
# file must keep its mode.
user=65532
check "CVE-2026-12345: TemporaryDirectory cleanup does not follow a swapped-in symlink" <<'EOF'
import contextlib, os, stat, tempfile
from unittest import mock
assert os.getuid() != 0
with tempfile.TemporaryDirectory() as target:
    target_file = os.path.join(target, 'file1')
    open(target_file, 'wb').close()
    os.chmod(target_file, 0o400)
    target_mode = os.stat(target_file).st_mode
    d1 = tempfile.TemporaryDirectory()
    dir1 = os.path.join(d1.name, 'dir1')
    os.mkdir(dir1)
    open(os.path.join(dir1, 'file1'), 'wb').close()
    os.chmod(dir1, 0o500)
    unlink = os.unlink
    def hook(path, *, dir_fd=None):
        try:
            return unlink(path, dir_fd=dir_fd)
        except PermissionError:
            if not os.path.islink(dir1):
                os.chmod(dir1, 0o700)
                os.rename(dir1, dir1 + '_moved')
                os.symlink(target, dir1)
            raise
    try:
        with mock.patch('os.unlink', hook):
            with contextlib.suppress(OSError):
                d1.cleanup()
    finally:
        if os.path.islink(dir1):
            os.unlink(dir1)
            os.rename(dir1 + '_moved', dir1)
        os.chmod(dir1, 0o700)
        d1.cleanup()
    assert os.path.exists(target_file), 'cleanup deleted a file outside the directory'
    mode = os.stat(target_file).st_mode
    assert mode == target_mode, f'cleanup changed an outside file mode: {stat.filemode(target_mode)} -> {stat.filemode(mode)}'
EOF
user=

if [ "$failures" -ne 0 ]; then
  echo "$failures check(s) failed" >&2
  exit 1
fi
