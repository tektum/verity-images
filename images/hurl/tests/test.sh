#!/bin/sh
set -eu

# Hurl runs against a loopback fixture server on the host network; no
# third-party endpoint is contacted.
image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^  version: "\([0-9][0-9.]*\)".*/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf '%s\n' 'hurl melange version not found' >&2; exit 1; }
work=$(mktemp -d)
server_pid=
cleanup() {
  [ -z "$server_pid" ] || kill "$server_pid" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

user=$(docker image inspect -f '{{.Config.User}}' "$image")
[ "$user" = 65532 ] || fail "image user is $user, want 65532"
entrypoint=$(docker image inspect -f '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' "$image")
[ "$entrypoint" = '["/usr/bin/hurl"] null' ] || fail "unexpected entrypoint: $entrypoint"
workdir=$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")
[ "$workdir" = /work ] || fail "unexpected working directory: $workdir"

version=$(docker run --rm --network none "$image" --version 2>&1) || fail "hurl --version failed: $version"
printf '%s\n' "$version" | head -n1 | grep "^hurl $expected_version (" >/dev/null ||
  fail "unexpected version: $version"
printf '%s\n' "$version" | grep -F 'Features' | grep -E '(^| )HTTP2( |$)' >/dev/null ||
  fail "hurl is missing HTTP/2 support: $version"

cat >"$work/server.py" <<'PY'
import http.server
import json
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        payload = json.dumps({"echo": json.loads(body)["name"], "method": "POST"}).encode()
        self.send_response(201)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w") as port_file:
    port_file.write(str(server.server_port))
server.serve_forever()
PY
python3 "$work/server.py" "$work/port" &
server_pid=$!
attempts=0
until [ -s "$work/port" ]; do
  kill -0 "$server_pid" 2>/dev/null || fail 'fixture server exited'
  attempts=$((attempts + 1))
  [ "$attempts" -lt 20 ] || fail 'fixture server did not start'
  sleep 1
done
port=$(cat "$work/port")

# A passing assertion file, read from the working directory.
cat >"$work/pass.hurl" <<EOF
POST http://127.0.0.1:$port/items
{"name": "verity"}
HTTP 201
[Asserts]
header "Content-Type" == "application/json"
jsonpath "\$.echo" == "verity"
jsonpath "\$.method" == "POST"
EOF
# A failing assertion must make hurl exit non-zero.
sed 's/== "verity"/== "other"/' "$work/pass.hurl" >"$work/fail.hurl"
chmod 0755 "$work"
chmod 0644 "$work"/*.hurl

out=$(timeout 60 docker run --rm --network host -v "$work:/work:ro" "$image" --test pass.hurl 2>&1) ||
  { printf '%s\n' "$out" >&2; fail 'passing hurl file failed'; }
printf '%s\n' "$out" | grep -E '^Succeeded files: +1 \(100\.0%\)$' >/dev/null ||
  { printf '%s\n' "$out" >&2; fail 'hurl did not report one succeeded file'; }

if out=$(timeout 60 docker run --rm --network host -v "$work:/work:ro" "$image" --test fail.hurl 2>&1); then
  printf '%s\n' "$out" >&2
  fail 'failing assertion exited zero'
fi
printf '%s\n' "$out" | grep -F 'Assert failure' >/dev/null ||
  { printf '%s\n' "$out" >&2; fail 'failing assertion was not reported'; }

printf 'SMOKE PASS image=%s\n' "$image"
