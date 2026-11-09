#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-alloy-test-$$"
volume="verity-alloy-data-$$"
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
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/alloy"]' ] \
  || fail 'unexpected image entrypoint'
docker run --rm "$image" --version 2>&1 | grep -F 'alloy, version v1.' >/dev/null \
  || fail 'alloy version check failed'

# The default command must start with the packaged configuration.
docker volume create "$volume" >/dev/null
docker run --name "$container" -d --read-only -v "$volume:/var/lib/alloy/data" \
  -p 127.0.0.1::12345 "$image" >/dev/null
port=$(docker port "$container" 12345/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || fail 'port 12345 was not published'
attempt=0
until response=$(curl --fail --silent --connect-timeout 1 --max-time 5 "http://127.0.0.1:$port/-/ready"); do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 60 ] || fail 'alloy did not become ready with the default configuration'
  sleep 1
done
printf '%s' "$response" | grep -F 'Alloy is ready' >/dev/null || fail 'readiness response was unexpected'
curl --fail --silent "http://127.0.0.1:$port/" | grep -Fi '<html' >/dev/null \
  || fail 'embedded Alloy UI was not served'
docker stop --time 30 "$container" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ] \
  || fail 'alloy did not stop cleanly'
docker rm "$container" >/dev/null

# Scrape the unix exporter and remote write to a sink on the host.
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

server = http.server.HTTPServer(("0.0.0.0", 0), Handler)
open(sys.argv[2], "w").write(str(server.server_port))
server.serve_forever()
EOF
python3 "$tmp/sink.py" "$tmp/received" "$tmp/sink-port" &
sink_pid=$!
trap 'kill "$sink_pid" 2>/dev/null || true; cleanup' EXIT HUP INT TERM
attempt=0
until [ -s "$tmp/sink-port" ]; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 10 ] || fail 'remote write sink did not start'
  sleep 1
done
sink_port=$(cat "$tmp/sink-port")

cat >"$tmp/config.alloy" <<EOF
prometheus.exporter.unix "host" { }

prometheus.scrape "host" {
  targets         = prometheus.exporter.unix.host.targets
  forward_to      = [prometheus.remote_write.sink.receiver]
  scrape_interval = "1s"
  scrape_timeout  = "1s"
}

prometheus.remote_write "sink" {
  endpoint {
    url = "http://host.docker.internal:$sink_port/api/v1/write"
  }
}
EOF
chmod 644 "$tmp/config.alloy"

docker run --name "$container" -d --read-only --add-host host.docker.internal:host-gateway \
  -v "$volume:/var/lib/alloy/data" -v "$tmp/config.alloy:/tmp/config.alloy:ro" \
  -p 127.0.0.1::12345 "$image" run --server.http.listen-addr=0.0.0.0:12345 \
  --storage.path=/var/lib/alloy/data /tmp/config.alloy >/dev/null
port=$(docker port "$container" 12345/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || fail 'port 12345 was not published'
attempt=0
until curl --fail --silent --connect-timeout 1 --max-time 5 "http://127.0.0.1:$port/-/ready" >/dev/null; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 60 ] || fail 'alloy did not become ready'
  sleep 1
done
attempt=0
until [ -s "$tmp/received" ]; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 60 ] || fail 'remote write sink received no samples'
  sleep 1
done
docker stop --time 30 "$container" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ] \
  || fail 'alloy did not stop cleanly'
docker rm "$container" >/dev/null

printf '%s\n' 'not valid {' >"$tmp/invalid.alloy"
chmod 644 "$tmp/invalid.alloy"
if invalid=$(docker run --rm -v "$volume:/var/lib/alloy/data" \
  -v "$tmp/invalid.alloy:/tmp/invalid.alloy:ro" "$image" run \
  --storage.path=/var/lib/alloy/data /tmp/invalid.alloy 2>&1); then
  fail 'invalid configuration unexpectedly succeeded'
fi
printf '%s' "$invalid" | grep -Ei 'error|failed' >/dev/null \
  || fail 'invalid configuration did not return a readable error'

printf 'SMOKE PASS image=%s\n' "$image"
