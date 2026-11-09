#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-vmagent-test-$$"
volume="verity-vmagent-data-$$"
tmp=$(mktemp -d)

fail() {
  docker logs "$container" >&2 2>&1 || true
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 10001 ] \
  || fail 'image user is not 10001'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/vmagent"]' ] \
  || fail 'unexpected image entrypoint'
[ "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["-remoteWrite.tmpDataPath=/vmagent-remotewrite-data"]' ] \
  || fail 'unexpected image command'
docker run --rm "$image" -version 2>&1 | grep -F 'vmagent-tags-v1.' >/dev/null \
  || fail 'vmagent version check failed'

# Phase 1: vmagent scrapes its own metrics endpoint while the remote write
# target is down, then stops cleanly. Phase 2: a fresh container on the same
# volume has no scrape config and starts the sink, so any request the sink
# receives is a sample replayed from the persistent queue.
cat >"$tmp/sink.py" <<'EOF'
import http.server
import sys

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.path == "/api/v1/write" and body:
            open(sys.argv[1], "ab").write(b"x")
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass

http.server.HTTPServer(("0.0.0.0", int(sys.argv[2])), Handler).serve_forever()
EOF
sink_port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("", 0)); print(s.getsockname()[1])')

cat >"$tmp/scrape.yml" <<'EOF'
scrape_configs:
  - job_name: self
    scrape_interval: 1s
    static_configs:
      - targets: ['127.0.0.1:8429']
EOF
chmod 644 "$tmp/scrape.yml"

docker volume create "$volume" >/dev/null

start() {
  docker run --name "$container" -d --read-only \
    --add-host host.docker.internal:host-gateway \
    -v "$volume:/vmagent-remotewrite-data" -v "$tmp/scrape.yml:/tmp/scrape.yml:ro" \
    -p 127.0.0.1::8429 "$image" \
    -remoteWrite.tmpDataPath=/vmagent-remotewrite-data \
    "-remoteWrite.url=http://host.docker.internal:$sink_port/api/v1/write" "$@" >/dev/null
  port=$(docker port "$container" 8429/tcp | awk -F: 'NR == 1 { print $2 }')
  [ -n "$port" ] || fail 'port 8429 was not published'
  attempt=0
  until response=$(curl --fail --silent --connect-timeout 1 --max-time 5 "http://127.0.0.1:$port/health"); do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 30 ] || fail 'vmagent did not become healthy'
    sleep 1
  done
  [ "$response" = OK ] || fail 'health response was not OK'
}

start -promscrape.config=/tmp/scrape.yml
attempt=0
until curl --fail --silent "http://127.0.0.1:$port/api/v1/targets" | grep -F '"health":"up"' >/dev/null; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 30 ] || fail 'self scrape target did not become up'
  sleep 1
done
sleep 5
docker stop --time 30 "$container" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ] \
  || fail 'vmagent did not stop cleanly'
docker rm "$container" >/dev/null

python3 "$tmp/sink.py" "$tmp/received" "$sink_port" &
sink_pid=$!
trap 'kill "$sink_pid" 2>/dev/null || true; cleanup' EXIT HUP INT TERM
start
attempt=0
until [ -s "$tmp/received" ]; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 30 ] || fail 'queued samples were not replayed after restart'
  sleep 1
done
docker stop --time 30 "$container" >/dev/null
docker rm "$container" >/dev/null

if invalid=$(docker run --rm "$image" -no-such-flag 2>&1); then
  fail 'invalid flag unexpectedly succeeded'
fi
printf '%s' "$invalid" | grep -Fi 'flag provided but not defined' >/dev/null \
  || fail 'invalid flag did not return a readable error'

printf 'SMOKE PASS image=%s\n' "$image"
