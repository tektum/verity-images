#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-vmalert-test-$$"
tmp=$(mktemp -d)

fail() {
  docker logs "$container" >&2 2>&1 || true
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  [ -z "${stub_pid:-}" ] || kill "$stub_pid" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 10001 ] \
  || fail 'image user is not 10001'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/vmalert"]' ] \
  || fail 'unexpected image entrypoint'
docker run --rm "$image" -version 2>&1 | grep -F 'vmalert-tags-v1.' >/dev/null \
  || fail 'vmalert version check failed'

# The stub datasource answers every instant query with one sample, so the
# alerting rule below must fire through a real query evaluation.
cat >"$tmp/stub.py" <<'PY'
import http.server
import sys

BODY = (b'{"status":"success","data":{"resultType":"vector","result":'
        b'[{"metric":{"job":"verity"},"value":[1700000000,"1"]}]}}')

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.reply()

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.reply()

    def reply(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(BODY)))
        self.end_headers()
        self.wfile.write(BODY)

    def log_message(self, *args):
        pass

http.server.HTTPServer(("0.0.0.0", int(sys.argv[1])), Handler).serve_forever()
PY
stub_port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("", 0)); print(s.getsockname()[1])')
python3 "$tmp/stub.py" "$stub_port" &
stub_pid=$!

cat >"$tmp/rules.yml" <<'YML'
groups:
  - name: verity-smoke
    interval: 1s
    rules:
      - alert: VeritySmokeFiring
        expr: verity_smoke_metric > 0
        labels:
          severity: smoke
YML
chmod 755 "$tmp"
chmod 644 "$tmp/rules.yml"

docker run --name "$container" -d --read-only \
  --add-host host.docker.internal:host-gateway \
  -v "$tmp/rules.yml:/etc/vmalert/rules.yml:ro" -p 127.0.0.1::8880 "$image" \
  -rule=/etc/vmalert/rules.yml \
  "-datasource.url=http://host.docker.internal:$stub_port" \
  -notifier.blackhole >/dev/null
port=$(docker port "$container" 8880/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || fail 'port 8880 was not published'
attempt=0
until response=$(curl --fail --silent --connect-timeout 1 --max-time 5 "http://127.0.0.1:$port/health"); do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 30 ] || fail 'vmalert did not become healthy'
  sleep 1
done
[ "$response" = OK ] || fail 'health response was not OK'

attempt=0
until curl --fail --silent --show-error "http://127.0.0.1:$port/api/v1/alerts" \
  | grep -F '"state":"firing"' | grep -F 'VeritySmokeFiring' >/dev/null; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 30 ] || fail 'alert rule did not fire against the datasource'
  sleep 1
done

docker stop --time 30 "$container" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ] \
  || fail 'vmalert did not stop cleanly'
docker rm "$container" >/dev/null

# An invalid rules file must fail startup with a readable error.
printf 'groups:\n  - name: broken\n    rules:\n      - alert: Broken\n' >"$tmp/broken.yml"
chmod 644 "$tmp/broken.yml"
if broken=$(docker run --rm -v "$tmp/broken.yml:/etc/vmalert/rules.yml:ro" "$image" \
  -rule=/etc/vmalert/rules.yml -datasource.url=http://127.0.0.1:1 -notifier.blackhole 2>&1); then
  fail 'invalid rules file unexpectedly succeeded'
fi
printf '%s' "$broken" | grep -Fi 'rules.yml' >/dev/null \
  || fail 'invalid rules file did not return a readable error'

if invalid=$(docker run --rm "$image" -no-such-flag 2>&1); then
  fail 'invalid flag unexpectedly succeeded'
fi
printf '%s' "$invalid" | grep -Fi 'flag provided but not defined' >/dev/null \
  || fail 'invalid flag did not return a readable error'

printf 'SMOKE PASS image=%s\n' "$image"
