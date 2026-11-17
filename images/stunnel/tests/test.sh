#!/bin/sh
set -eu

# stunnel wraps a plain local TCP service with TLS using a throwaway test CA.
# Everything shares one network namespace with --network none:
#   backend  : pinned Python helper, plain TCP echo on 127.0.0.1:7000
#   server   : image under test, TLS on 127.0.0.1:8443 -> 127.0.0.1:7000
#   client   : image under test in client mode, plain 127.0.0.1:9000 -> TLS 8443,
#              verifying the server chain against the test CA
# A second client trusts an unrelated CA and must not relay any data.

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*- stunnel=\([0-9][0-9.]*\)-r[0-9][0-9]*$/\1/p' \
  "$(dirname "$0")/../apko.yaml")
python_index=ghcr.io/tektum/python@sha256:d059268a2e4f0ef0cc82bb50c847e69e16e174736758013a153cb36311fa6dd6
label="verity-test=stunnel-$$"
backend=verity-stunnel-backend-$$
work=$(mktemp -d)

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -f >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  for c in $(docker ps -aq --filter "label=$label"); do
    docker logs "$c" >&2 2>&1 || true
  done
  exit 1
}

[ -n "$expected_version" ] || fail 'stunnel package version not found'

inspect() {
  docker image inspect --format "$1" "$image"
}

[ "$(inspect '{{.Config.User}}')" = 65532 ] || fail 'unexpected OCI user'
[ "$(inspect '{{json .Config.Entrypoint}}')" = '["/usr/bin/stunnel"]' ] ||
  fail "unexpected entrypoint: $(inspect '{{json .Config.Entrypoint}}')"

version=$(docker run --rm --network none "$image" -version 2>&1 || true)
printf '%s\n' "$version" | grep -q "stunnel ${expected_version} " ||
  fail "unexpected stunnel version: $version"

# Test PKI: a CA, a server certificate for 127.0.0.1, and an unrelated CA.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=verity-test-ca' \
  -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' \
  -keyout "$work/ca.key" -out "$work/ca.pem" >/dev/null 2>&1 || fail 'could not create test CA'
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=verity-other-ca' \
  -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' \
  -keyout "$work/other.key" -out "$work/other.pem" >/dev/null 2>&1 || fail 'could not create second CA'
openssl req -newkey rsa:2048 -nodes -subj '/CN=127.0.0.1' \
  -keyout "$work/server.key" -out "$work/server.csr" >/dev/null 2>&1 || fail 'could not create server CSR'
cat >"$work/san.ext" <<'EOF'
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = IP:127.0.0.1
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
EOF
openssl x509 -req -in "$work/server.csr" -CA "$work/ca.pem" -CAkey "$work/ca.key" \
  -CAcreateserial -days 1 -extfile "$work/san.ext" -out "$work/server.pem" >/dev/null 2>&1 ||
  fail 'could not sign server certificate'

cat >"$work/server.conf" <<'EOF'
foreground = yes
pid =
[wrap]
accept = 127.0.0.1:8443
connect = 127.0.0.1:7000
cert = /tls/server.pem
key = /tls/server.key
EOF

client_conf() {
  cat >"$work/$1.conf" <<EOF
foreground = yes
pid =
[wrap]
client = yes
accept = 127.0.0.1:$2
connect = 127.0.0.1:8443
CAfile = /tls/$3
verifyChain = yes
checkIP = 127.0.0.1
EOF
}
client_conf client 9000 ca.pem
client_conf untrusted 9001 other.pem

cat >"$work/echo.py" <<'EOF'
import socketserver

class Echo(socketserver.StreamRequestHandler):
    def handle(self):
        line = self.rfile.readline()
        self.wfile.write(b"backend:" + line)

socketserver.TCPServer.allow_reuse_address = True
socketserver.TCPServer(("127.0.0.1", 7000), Echo).serve_forever()
EOF

cat >"$work/probe.py" <<'EOF'
import socket, ssl, sys, time

mode, port = sys.argv[1], int(sys.argv[2])
deadline = time.time() + 30
last = None
while time.time() < deadline:
    try:
        sock = socket.create_connection(("127.0.0.1", port), timeout=5)
        if mode == "tls":
            ctx = ssl.create_default_context(cafile="/tls/ca.pem")
            sock = ctx.wrap_socket(sock, server_hostname="127.0.0.1")
            print("tls-version:" + sock.version())
        sock.sendall(b"ping\n")
        data = b""
        while True:
            chunk = sock.recv(256)
            if not chunk:
                break
            data += chunk
        print(data.decode().strip())
        sys.exit(0 if data else 3)
    except (ConnectionRefusedError, ConnectionResetError, ssl.SSLError, OSError) as exc:
        last = exc
        if mode == "once":
            break
        time.sleep(0.5)
print("error:%r" % (last,))
sys.exit(2)
EOF
chmod -R a+rX "$work"

docker run -d --label "$label" --name "$backend" --network none -v "$work:/tls:ro" \
  "$python_index" /tls/echo.py >/dev/null || fail 'backend did not start'

for name in server client untrusted; do
  docker run -d --label "$label" --name "verity-stunnel-$name-$$" --network "container:$backend" \
    -v "$work:/tls:ro" "$image" "/tls/$name.conf" >/dev/null || fail "stunnel $name did not start"
done

probe() {
  docker run --rm --label "$label" --network "container:$backend" -v "$work:/tls:ro" \
    "$python_index" /tls/probe.py "$@"
}

# Direct TLS client verifies the server certificate against the test CA.
direct=$(probe tls 8443) || fail "direct TLS probe failed: $direct"
printf '%s\n' "$direct" | grep -q '^tls-version:TLSv1\.[23]$' || fail "unexpected TLS version: $direct"
printf '%s\n' "$direct" | grep -qx 'backend:ping' || fail "TLS reply did not come from the backend: $direct"

# A stunnel client with the right CA relays plain TCP through the TLS tunnel.
relayed=$(probe tcp 9000) || fail "tunnelled probe failed: $relayed"
[ "$relayed" = 'backend:ping' ] || fail "unexpected tunnelled reply: $relayed"

# A stunnel client trusting an unrelated CA must refuse the server and relay nothing.
status=0
rejected=$(probe once 9001) || status=$?
[ "$status" != 0 ] || fail "untrusted client relayed data: $rejected"
docker logs "verity-stunnel-untrusted-$$" 2>&1 | grep -qi 'certificate verify failed\|CERT: Verification error\|unable to get local issuer' ||
  fail 'untrusted client did not log a certificate verification failure'

printf 'SMOKE PASS version=%s\n' "$expected_version"
