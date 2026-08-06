#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
tempdir=$(mktemp -d)
http_pid=
https_pid=

cleanup() {
  [ -z "$http_pid" ] || kill "$http_pid" >/dev/null 2>&1 || true
  [ -z "$https_pid" ] || kill "$https_pid" >/dev/null 2>&1 || true
  rm -rf "$tempdir"
}
trap cleanup EXIT INT TERM

cat >"$tempdir/server.py" <<'PY'
import functools
import http.server
import ssl
import sys


class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_args):
        pass


handler = functools.partial(Handler, directory=sys.argv[2])
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
if len(sys.argv) == 5:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(sys.argv[3], sys.argv[4])
    server.socket = context.wrap_socket(server.socket, server_side=True)
with open(sys.argv[1], "w", encoding="ascii") as port_file:
    port_file.write(str(server.server_port))
server.serve_forever()
PY

wait_for_port() {
  attempts=0
  until [ -s "$1" ]; do
    if ! kill -0 "$2"; then
      printf 'fixture process %s exited before writing %s\n' "$2" "$1" >&2
      return 1
    fi
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 20 ]; then
      printf 'timed out waiting for %s\n' "$1" >&2
      return 1
    fi
    sleep 1
  done
}

[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/curl"]' ]
case $(docker image inspect --format '{{json .Config.Cmd}}' "$image") in null|'[]') ;; *) exit 1;; esac
docker run --rm "$image" --version | grep -q '^curl 8\.'

printf 'curl fixture\n' >"$tempdir/fixture.txt"
python3 "$tempdir/server.py" "$tempdir/http.port" "$tempdir" &
http_pid=$!
wait_for_port "$tempdir/http.port" "$http_pid"
http_port=$(cat "$tempdir/http.port")
[ "$(docker run --rm --network host "$image" --fail --silent --max-time 10 \
  "http://127.0.0.1:$http_port/fixture.txt")" = 'curl fixture' ]

openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 -subj /CN=localhost \
  -addext subjectAltName=DNS:localhost -keyout "$tempdir/tls.key" \
  -out "$tempdir/tls.crt" >/dev/null 2>&1
python3 "$tempdir/server.py" "$tempdir/https.port" "$tempdir" \
  "$tempdir/tls.crt" "$tempdir/tls.key" &
https_pid=$!
wait_for_port "$tempdir/https.port" "$https_pid"
https_port=$(cat "$tempdir/https.port")
[ "$(docker run --rm --network host -v "$tempdir/tls.crt:/tmp/ca.crt:ro" "$image" \
  --fail --silent --max-time 10 --cacert /tmp/ca.crt \
  "https://localhost:$https_port/fixture.txt")" = 'curl fixture' ]

if docker run --rm "$image" --fail --silent --max-time 10 'http://[::1'; then
  exit 1
fi
if docker run --rm --network host "$image" --fail --silent --max-time 10 \
  "https://localhost:$https_port/fixture.txt"; then
  exit 1
fi

printf 'SMOKE PASS image=%s\n' "$image"
