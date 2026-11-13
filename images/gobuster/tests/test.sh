#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
config="$(dirname "$0")/../apko.yaml"
version=$(sed -n 's/^    - gobuster=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
work=$(mktemp -d)
server_pid=

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail 'could not read the pinned gobuster version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/gobuster"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

docker run --rm --network none "$image" --version >"$work/version" 2>&1 ||
  fail 'version failed'
grep -Fx "gobuster version $version" "$work/version" >/dev/null ||
  fail "version does not report gobuster $version: $(cat "$work/version")"

rc=0
docker run --rm --network none "$image" --definitely-invalid >"$work/invalid" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'flag provided but not defined' "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"

# Local target only: an HTTP server on the host loopback that serves exactly
# one hidden path. Nothing leaves the runner.
cat >"$work/server.py" <<'PY'
import http.server
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.rstrip("/") == "/verity-admin":
            body = b"verity ok\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
        else:
            body = b""
            self.send_response(404)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command == "GET":
            self.wfile.write(body)

    do_HEAD = do_GET

    def log_message(self, *args):
        with open(sys.argv[2], "a", encoding="ascii") as log:
            log.write(self.path + "\n")


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w", encoding="ascii") as port_file:
    port_file.write(str(server.server_port))
server.serve_forever()
PY
python3 "$work/server.py" "$work/port" "$work/requests.log" &
server_pid=$!
attempt=0
until [ -s "$work/port" ]; do
  kill -0 "$server_pid" 2>/dev/null || fail 'target fixture exited early'
  attempt=$((attempt + 1))
  [ "$attempt" -lt 20 ] || fail 'target fixture did not start'
  sleep 1
done
port=$(cat "$work/port")

printf 'verity-admin\nverity-missing\nverity-nothing\n' >"$work/words.txt"
chmod 755 "$work"
chmod 644 "$work/words.txt"

docker run --rm --network host --cap-drop=ALL --read-only \
  -v "$work/words.txt:/work/words.txt:ro" "$image" \
  dir -u "http://127.0.0.1:$port" -w /work/words.txt -q --np --nc -t 1 >"$work/dir.out" 2>&1 ||
  fail "dir mode failed: $(cat "$work/dir.out")"
grep -E '^/?verity-admin +\(Status: 200\) \[Size: 10\]' "$work/dir.out" >/dev/null ||
  fail "dir mode did not report the hidden path: $(cat "$work/dir.out")"
if grep -E 'verity-(missing|nothing)' "$work/dir.out" >/dev/null; then
  fail "dir mode reported a 404 path: $(cat "$work/dir.out")"
fi
for w in verity-admin verity-missing verity-nothing; do
  grep -F "/$w" "$work/requests.log" >/dev/null || fail "target never saw a request for /$w"
done

# Negative: an unreachable target is an error, not an empty result.
kill "$server_pid" >/dev/null 2>&1 || true
wait "$server_pid" 2>/dev/null || true
server_pid=
rc=0
docker run --rm --network host --cap-drop=ALL --read-only \
  -v "$work/words.txt:/work/words.txt:ro" "$image" \
  dir -u "http://127.0.0.1:$port" -w /work/words.txt -q --np --nc -t 1 >"$work/down.out" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'scan of a stopped target unexpectedly succeeded'
grep -F 'connection refused' "$work/down.out" >/dev/null ||
  fail "unreachable target diagnostic is missing: $(cat "$work/down.out")"

printf 'SMOKE PASS image=%s\n' "$image"
