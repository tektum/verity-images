#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
work=$(mktemp -d)
container="verity-falcosidekick-test-$$"
sink_pid=

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  [ -z "$sink_pid" ] || kill "$sink_pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  docker logs "$container" >&2 2>&1 || true
  exit 1
}

[ "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532 ] ||
  fail 'unexpected image config: User'
[ "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/falcosidekick"]' ] ||
  fail 'unexpected image config: Entrypoint'

docker run --rm --network none "$image" --version >"$work/version" 2>&1 ||
  fail 'falcosidekick --version failed'
grep -Eq "^GitVersion: +$expected_version\$" "$work/version" ||
  fail "version output does not report $expected_version"

# Webhook sink on the host: records every request body, one per line.
cat >"$work/sink.py" <<'PY'
import os
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        with open(sys.argv[2], "ab") as out:
            out.write(body + b"\n")
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
probe = socket.socket()
probe.bind(("127.0.0.1", 0))
listen_port = probe.getsockname()[1]
probe.close()
with open(sys.argv[1] + ".tmp", "w") as out:
    out.write(f"{server.server_port} {listen_port}\n")
os.replace(sys.argv[1] + ".tmp", sys.argv[1])
server.serve_forever()
PY
: >"$work/received"
python3 "$work/sink.py" "$work/ports" "$work/received" &
sink_pid=$!
attempts=0
until [ -s "$work/ports" ]; do
  kill -0 "$sink_pid" 2>/dev/null || fail 'webhook sink failed to start'
  attempts=$((attempts + 1))
  [ "$attempts" -lt 100 ] || fail 'webhook sink did not report its port'
  sleep 0.1
done
read -r sink_port port <"$work/ports"

docker run --name "$container" -d --network host --read-only \
  -e LISTENADDRESS=127.0.0.1 -e LISTENPORT="$port" \
  -e WEBHOOK_ADDRESS="http://127.0.0.1:$sink_port/falco" \
  "$image" >/dev/null || fail 'falcosidekick container failed to start'

attempts=0
until curl --fail --silent --connect-timeout 1 --max-time 5 \
  "http://127.0.0.1:$port/ping" >"$work/ping"; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 120 ] || fail 'falcosidekick did not become ready'
  sleep 1
done
[ "$(cat "$work/ping")" = pong ] || fail 'GET /ping did not return pong'
curl --fail --silent --show-error "http://127.0.0.1:$port/healthz" >"$work/healthz" ||
  fail 'GET /healthz failed'
grep -F '"status": "ok"' "$work/healthz" >/dev/null || fail 'healthz body is not ok'
docker logs "$container" 2>&1 | grep -F 'Enabled Outputs' | grep -F Webhook >/dev/null ||
  fail 'webhook output is not enabled'

curl --fail --silent --show-error -X POST "http://127.0.0.1:$port/" \
  -H 'Content-Type: application/json' \
  -d '{"output":"verity smoke event","priority":"Critical","rule":"Verity smoke rule","time":"2026-01-01T00:00:00.000000000Z","source":"syscalls","hostname":"verity","output_fields":{"proc.name":"verity-smoke"}}' \
  >/dev/null || fail 'POST of a Falco event was rejected'

attempts=0
until grep -F '"rule":"Verity smoke rule"' "$work/received" >/dev/null; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || fail 'webhook sink did not receive the event'
  sleep 1
done
grep -F '"priority":"Critical"' "$work/received" >/dev/null ||
  fail 'forwarded event lost its priority'

if curl --fail --silent -X POST "http://127.0.0.1:$port/" \
  -H 'Content-Type: application/json' -d 'not json' >/dev/null 2>&1; then
  fail 'malformed event body was accepted'
fi

started=$(date +%s)
docker stop -t 10 "$container" >/dev/null
elapsed=$(($(date +%s) - started))
[ "$elapsed" -lt 10 ] || fail 'falcosidekick did not stop on SIGTERM before the kill timeout'
# Upstream installs no SIGTERM handler, so the Go runtime exits with status 2
# instead of the 137 a SIGKILL after the stop timeout would leave.
[ "$(docker inspect "$container" --format '{{.State.ExitCode}}')" = 2 ] ||
  fail 'falcosidekick did not exit through the Go runtime SIGTERM path'

if docker run --rm --network none "$image" -c /nonexistent/config.yaml >"$work/invalid.log" 2>&1; then
  fail 'missing config file unexpectedly succeeded'
fi
grep -F '/nonexistent/config.yaml' "$work/invalid.log" >/dev/null || {
  cat "$work/invalid.log" >&2
  fail 'missing config error is not readable'
}

printf 'SMOKE PASS image=%s\n' "$image"
