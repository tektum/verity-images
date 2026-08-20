#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
: "${IMAGE_VERSION:?IMAGE_VERSION is required}"
container="verity-blackbox-exporter-test-$$"
fixture=$(mktemp -d)
target_pid=

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  [ -z "$target_pid" ] || kill "$target_pid" >/dev/null 2>&1 || true
  rm -rf "$fixture"
}
trap cleanup EXIT INT TERM

test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/blackbox_exporter"]'
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532
docker run --rm --entrypoint /usr/bin/blackbox_exporter "$image" --version 2>&1 |
  grep -F "blackbox_exporter, version ${IMAGE_VERSION}"

cat >"$fixture/target-server.py" <<'PY'
import functools
import http.server
import sys

handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[2])
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
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

printf 'blackbox target fixture\n' >"$fixture/index.html"
python3 "$fixture/target-server.py" "$fixture/target.port" "$fixture" &
target_pid=$!
wait_for_port "$fixture/target.port" "$target_pid"
target_port=$(cat "$fixture/target.port")

cat >"$fixture/blackbox.yml" <<'EOF'
modules:
  http_2xx:
    prober: http
    timeout: 5s
    http:
      valid_status_codes: []
      method: GET
EOF
chmod 644 "$fixture/blackbox.yml"

docker run --name "$container" -d --network host --read-only --user 65532 \
  -v "$fixture/blackbox.yml:/etc/blackbox_exporter/blackbox.yml:ro" \
  "$image" --config.file=/etc/blackbox_exporter/blackbox.yml >/dev/null

i=0
until curl --fail --silent --connect-timeout 1 --max-time 5 \
  'http://127.0.0.1:9115/metrics' >/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 20 ] || { docker logs "$container" >&2 || true; exit 1; }
  sleep 1
done

probe=$(curl --fail --silent --max-time 5 \
  "http://127.0.0.1:9115/probe?target=http%3A%2F%2F127.0.0.1%3A${target_port}%2Findex.html&module=http_2xx")
printf '%s\n' "$probe" | grep -Fxq 'probe_success 1'

status=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 \
  "http://127.0.0.1:9115/probe?target=http%3A%2F%2F127.0.0.1%3A${target_port}%2Findex.html&module=does-not-exist")
[ "$status" = 400 ]

docker stop "$container" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ]

printf 'SMOKE PASS image=%s\n' "$image"
