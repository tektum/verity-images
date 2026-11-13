#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
server_pid=

cleanup() {
  [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/hey"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

# Target fixture: a loopback server that records each request's method, path and
# custom header, answers 200 on /ok and 404 elsewhere.
cat >"$work/server.py" <<'PY'
import http.server
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def handle_one(self):
        with open(sys.argv[2], "a", encoding="ascii") as log:
            log.write(f"{self.command} {self.path} {self.headers.get('X-Smoke', '-')}\n")
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        status = 200 if self.path == "/ok" else 404
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = do_POST = handle_one

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w", encoding="ascii") as port_file:
    port_file.write(str(server.server_port))
server.serve_forever()
PY
: >"$work/requests"
python3 "$work/server.py" "$work/port" "$work/requests" &
server_pid=$!
attempt=0
until [ -s "$work/port" ]; do
  kill -0 "$server_pid" 2>/dev/null || fail 'target fixture exited early'
  attempt=$((attempt + 1))
  [ "$attempt" -lt 20 ] || fail 'target fixture did not start'
  sleep 1
done
port=$(cat "$work/port")

run() {
  docker run --rm --network host --read-only "$image" "$@"
}

# Usage without a URL exits non-zero.
rc=0
docker run --rm --network none "$image" >"$work/usage" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'missing URL unexpectedly succeeded'
grep -F 'Usage: hey [options...] <url>' "$work/usage" >/dev/null || fail 'usage text is missing'

# Negative: an unknown flag exits non-zero with a diagnostic.
rc=0
docker run --rm --network none "$image" --no-such-flag >"$work/flag" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'unknown flag unexpectedly succeeded'
grep -F 'flag provided but not defined: -no-such-flag' "$work/flag" >/dev/null ||
  fail "unknown flag diagnostic is missing: $(cat "$work/flag")"

# 20 GET requests over 4 workers: summary and an all-200 status distribution.
run -n 20 -c 4 -H 'X-Smoke: get' "http://127.0.0.1:$port/ok" >"$work/get" ||
  fail 'GET run failed'
grep -F 'Summary:' "$work/get" >/dev/null || fail 'summary is missing'
grep -F 'Requests/sec:' "$work/get" >/dev/null || fail 'request rate is missing'
grep -Ex '[[:space:]]+\[200\][[:space:]]+20 responses' "$work/get" >/dev/null ||
  fail "unexpected GET status distribution: $(cat "$work/get")"
test "$(grep -cx 'GET /ok get' "$work/requests")" -eq 20 ||
  fail 'server did not receive 20 GET requests with the custom header'

# POST with a body, and 404 responses are reported in the distribution.
run -n 5 -c 1 -m POST -d 'payload' "http://127.0.0.1:$port/missing" >"$work/post" ||
  fail 'POST run failed'
grep -Ex '[[:space:]]+\[404\][[:space:]]+5 responses' "$work/post" >/dev/null ||
  fail "unexpected POST status distribution: $(cat "$work/post")"
test "$(grep -cx 'POST /missing -' "$work/requests")" -eq 5 ||
  fail 'server did not receive 5 POST requests'

# CSV output emits one row per request.
run -n 3 -c 1 -o csv "http://127.0.0.1:$port/ok" >"$work/csv" || fail 'CSV run failed'
head -n 1 "$work/csv" | grep -E '^response-time,DNS\+dialup,DNS,Request-write,Response-delay,Response-read,status-code,offset$' >/dev/null ||
  fail "unexpected CSV header: $(head -n 1 "$work/csv")"
test "$(grep -c ',200,' "$work/csv")" -eq 3 || fail 'CSV does not hold three 200 rows'

# Negative: a refused connection is reported in the error distribution.
run -n 3 -c 1 "http://127.0.0.1:1/" >"$work/refused" 2>&1 || true
grep -F 'Error distribution:' "$work/refused" >/dev/null ||
  fail "connection errors are not reported: $(cat "$work/refused")"
grep -F 'connection refused' "$work/refused" >/dev/null ||
  fail 'refused connection diagnostic is missing'

printf 'SMOKE PASS\n'
