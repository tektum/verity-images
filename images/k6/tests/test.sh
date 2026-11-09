#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
fixture=$(mktemp -d)
target_pid=

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  [ -z "$target_pid" ] || kill "$target_pid" >/dev/null 2>&1 || true
  rm -rf "$fixture"
}
trap cleanup EXIT HUP INT TERM

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] \
  || fail 'image user is not 65532'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/k6"]' ] \
  || fail 'unexpected image entrypoint'
[ "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/k6 ] \
  || fail 'unexpected image working directory'
docker run --rm --read-only "$image" version 2>&1 | grep -E '^k6 v[0-9]+\.[0-9]+\.[0-9]+' >/dev/null \
  || fail 'k6 version output was unexpected'

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

cat >"$fixture/pass.js" <<'JS'
import http from 'k6/http';
import { check } from 'k6';

export const options = {
  vus: 1,
  iterations: 1,
  thresholds: { checks: ['rate==1'] },
};

export default function () {
  const res = http.get(`${__ENV.TARGET}/health.json`);
  check(res, {
    'status is 200': (r) => r.status === 200,
    'body reports UP': (r) => r.json('status') === 'UP',
  });
}
JS

cat >"$fixture/fail.js" <<'JS'
import http from 'k6/http';
import { check } from 'k6';

export const options = {
  vus: 1,
  iterations: 1,
  thresholds: { checks: ['rate==1'] },
};

export default function () {
  const res = http.get(`${__ENV.TARGET}/missing.json`);
  check(res, { 'status is 200': (r) => r.status === 200 });
}
JS

printf 'export default function () { this is not valid javascript }\n' >"$fixture/broken.js"
chmod 755 "$fixture"
chmod 644 "$fixture"/*.js

run_k6() {
  docker run --rm --network host --read-only \
    -e "TARGET=http://127.0.0.1:$target_port" \
    -v "$fixture:/scripts:ro" \
    "$image" run --quiet --no-usage-report "$@" 2>&1
}

# A one-iteration run against the fixture must pass every check and exit 0.
set +e
output=$(run_k6 /scripts/pass.js)
code=$?
set -e
[ "$code" -eq 0 ] || fail "k6 run failed with exit $code: $output"
printf '%s\n' "$output" | grep -E 'checks_succeeded.*100\.00%.*2 out of 2' >/dev/null \
  || fail "checks did not all pass: $output"
printf '%s\n' "$output" | grep -E 'iterations.*: 1 ' >/dev/null \
  || fail "expected exactly one iteration: $output"

# Negative: a crossed threshold exits 99 and names the threshold.
set +e
output=$(run_k6 /scripts/fail.js)
code=$?
set -e
[ "$code" -eq 99 ] || fail "failing threshold exited $code, expected 99: $output"
printf '%s\n' "$output" | grep -F 'thresholds on metrics' >/dev/null \
  || fail "threshold failure was not reported: $output"

# Negative: a script that does not parse exits non-zero with a readable error.
set +e
output=$(run_k6 /scripts/broken.js)
code=$?
set -e
[ "$code" -ne 0 ] || fail 'k6 accepted a broken script'
[ "$code" -ne 99 ] || fail "broken script exited with the threshold code: $output"
printf '%s\n' "$output" | grep -F 'broken.js' >/dev/null \
  || fail "script error did not name the script: $output"

printf 'SMOKE PASS image=%s\n' "$image"
