#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-mongodb-exporter-test-$$"

fail() {
  docker logs "$container" >&2 2>&1 || true
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] \
  || fail 'image user is not 65532'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/mongodb_exporter"]' ] \
  || fail 'unexpected image entrypoint'
docker run --rm "$image" --version 2>&1 | grep -F 'Version: v0.' >/dev/null \
  || fail 'mongodb_exporter version check failed'

# No MongoDB server is available to the image gate, so the exporter must come
# up with an unreachable URI and report mongodb_up 0 instead of exiting.
docker run --name "$container" -d --read-only -p 127.0.0.1::9216 "$image" \
  '--mongodb.uri=mongodb://127.0.0.1:1/?connectTimeoutMS=1000&serverSelectionTimeoutMS=1000' \
  --collect-all >/dev/null
port=$(docker port "$container" 9216/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || fail 'port 9216 was not published'
attempt=0
until metrics=$(curl --fail --silent --connect-timeout 1 --max-time 10 "http://127.0.0.1:$port/metrics"); do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 30 ] || fail 'mongodb_exporter did not serve /metrics'
  sleep 1
done
printf '%s\n' "$metrics" | grep -E '^mongodb_up(\{[^}]*\})? 0$' >/dev/null \
  || fail 'mongodb_up was not 0 for an unreachable server'
printf '%s\n' "$metrics" | grep -F 'go_goroutines' >/dev/null \
  || fail 'exporter did not expose its own runtime metrics'

# The exporter does not install a SIGTERM handler, so the runtime default
# exit status 143 (128 + SIGTERM) is its stop contract.
docker stop --time 30 "$container" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 143 ] \
  || fail 'mongodb_exporter did not stop on SIGTERM'
docker rm "$container" >/dev/null

if invalid=$(docker run --rm "$image" --no-such-flag 2>&1); then
  fail 'invalid flag unexpectedly succeeded'
fi
printf '%s' "$invalid" | grep -F 'unknown flag --no-such-flag' >/dev/null \
  || fail 'invalid flag did not return a readable error'

printf 'SMOKE PASS image=%s\n' "$image"
