#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-gatus-test-$$"
fixture=$(mktemp -d)
target_pid=

fail() {
  docker logs "$container" >&2 2>&1 || true
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  [ -z "$target_pid" ] || kill "$target_pid" >/dev/null 2>&1 || true
  rm -rf "$fixture"
}
trap cleanup EXIT HUP INT TERM

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] \
  || fail 'image user is not 65532'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/gatus"]' ] \
  || fail 'unexpected image entrypoint'
[ "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = / ] \
  || fail 'unexpected image working directory'

# Target fixture: a local http.server with one healthy and one missing path.
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
printf '{"status":"UP"}\n' >"$fixture/health.json"
python3 "$fixture/target-server.py" "$fixture/target.port" "$fixture" &
target_pid=$!
attempt=0
until [ -s "$fixture/target.port" ]; do
  kill -0 "$target_pid" 2>/dev/null || fail 'target fixture exited early'
  attempt=$((attempt + 1))
  [ "$attempt" -lt 20 ] || fail 'target fixture did not start'
  sleep 1
done
target_port=$(cat "$fixture/target.port")

# Free port for the Gatus web server, so the test never collides with a host
# service on 8080 (the container uses the host network to reach the fixture).
web_port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')

cat >"$fixture/config.yaml" <<CFG
web:
  address: 127.0.0.1
  port: $web_port
metrics: true
endpoints:
  - name: fixture-up
    group: smoke
    url: "http://127.0.0.1:$target_port/health.json"
    interval: 2s
    conditions:
      - "[STATUS] == 200"
      - "[BODY].status == UP"
  - name: fixture-missing
    group: smoke
    url: "http://127.0.0.1:$target_port/missing.json"
    interval: 2s
    conditions:
      - "[STATUS] == 200"
CFG
chmod 644 "$fixture/config.yaml"

# The configuration is mounted at the default path, /config/config.yaml.
docker run --name "$container" -d --network host --read-only \
  -v "$fixture/config.yaml:/config/config.yaml:ro" \
  "$image" >/dev/null

attempt=0
until health=$(curl --fail --silent --connect-timeout 1 --max-time 5 "http://127.0.0.1:$web_port/health"); do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 30 ] || fail 'gatus did not become ready'
  sleep 1
done
printf '%s' "$health" | grep -F '"status":"UP"' >/dev/null || fail "unexpected health response: $health"

# Wait for both endpoints to be evaluated, then assert their real outcome.
attempt=0
while :; do
  statuses=$(curl --fail --silent --max-time 5 "http://127.0.0.1:$web_port/api/v1/endpoints/statuses") \
    || fail 'statuses API request failed'
  if printf '%s' "$statuses" | python3 -c '
import json, sys
by_name = {e["name"]: e for e in json.load(sys.stdin)}
sys.exit(0 if all(by_name.get(n, {}).get("results") for n in ("fixture-up", "fixture-missing")) else 1)
'; then
    break
  fi
  attempt=$((attempt + 1))
  [ "$attempt" -lt 30 ] || fail "endpoints were not evaluated: $statuses"
  sleep 1
done
printf '%s' "$statuses" | python3 -c '
import json, sys
by_name = {e["name"]: e for e in json.load(sys.stdin)}
up = by_name["fixture-up"]["results"][-1]
missing = by_name["fixture-missing"]["results"][-1]
assert up["success"] is True, "fixture-up success is %r" % (up["success"],)
assert up["status"] == 200, "fixture-up status is %r" % (up["status"],)
assert all(c["success"] for c in up["conditionResults"]), "fixture-up has failed conditions"
assert missing["success"] is False, "fixture-missing success is %r" % (missing["success"],)
assert missing["status"] == 404, "fixture-missing status is %r" % (missing["status"],)
' || fail "unexpected endpoint statuses: $statuses"

curl --fail --silent --max-time 5 "http://127.0.0.1:$web_port/" | grep -iF 'gatus' >/dev/null \
  || fail 'web UI was not served'
curl --fail --silent --max-time 5 "http://127.0.0.1:$web_port/metrics" \
  | grep -F 'gatus_results_total' >/dev/null || fail 'Prometheus metrics were not served'

docker stop --time 30 "$container" >/dev/null
code=$(docker inspect --format '{{.State.ExitCode}}' "$container")
[ "$code" = 0 ] || fail "gatus did not stop cleanly on SIGTERM (exit $code)"
docker rm "$container" >/dev/null

# Negative: an invalid configuration must exit non-zero with a readable error.
cat >"$fixture/invalid.yaml" <<'CFG'
endpoints:
  - name: broken
    url: "http://127.0.0.1:1/"
    conditions:
      - "[STATUS] is not a valid condition"
CFG
chmod 644 "$fixture/invalid.yaml"
set +e
output=$(docker run --name "$container" --network none --read-only \
  -e GATUS_CONFIG_PATH=/tmp/invalid.yaml \
  -v "$fixture/invalid.yaml:/tmp/invalid.yaml:ro" \
  "$image" 2>&1)
code=$?
set -e
[ "$code" -ne 0 ] || fail 'gatus accepted an invalid configuration'
printf '%s\n' "$output" | grep -F 'error parsing config' >/dev/null \
  || fail "invalid configuration error was not readable: $output"

printf 'SMOKE PASS image=%s\n' "$image"
