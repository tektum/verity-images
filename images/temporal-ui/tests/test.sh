#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)"$/\1/p' \
  "$(dirname "$0")/../melange.yaml" | sed -n 1p)
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
container="verity-temporal-ui-test-$$"
work=$(mktemp -d)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  docker logs "$container" >&2 2>&1 || true
  exit 1
}

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /home/ui-server ] ||
  fail 'unexpected OCI working directory'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' "$image")" = \
  '["/home/ui-server/ui-server"] ["--env","docker","start"]' ] || fail 'unexpected OCI command'

version=$(docker run --rm --network none "$image" --version)
case "$version" in
  *"$expected_version"*) ;;
  *) fail "ui-server version '$version' does not contain $expected_version" ;;
esac

# Negative: an invalid configuration value exits non-zero with a readable error.
if docker run --rm --network none -e TEMPORAL_UI_PORT=notaport "$image" >"$work/badconfig.log" 2>&1; then
  fail 'start with an invalid port unexpectedly succeeded'
fi
grep -q 'config file corrupted' "$work/badconfig.log" || {
  cat "$work/badconfig.log" >&2
  fail 'invalid configuration error is not readable'
}

# No Temporal backend is needed for the UI to serve its assets and settings.
docker run --name "$container" -d --read-only --tmpfs /tmp:uid=65532,gid=65532 \
  -e TEMPORAL_ADDRESS=127.0.0.1:1 -p 127.0.0.1::8080 "$image" >/dev/null
port=$(docker port "$container" 8080/tcp | awk -F: 'NR == 1 { print $NF }')
[ -n "$port" ] || fail 'no published port'
base="http://127.0.0.1:$port"

i=0
until curl --fail --silent --max-time 5 "$base/healthz" >"$work/healthz.json" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'temporal ui never became ready on :8080'
  sleep 1
done
grep -q 'OK' "$work/healthz.json" || { cat "$work/healthz.json" >&2; fail 'unexpected /healthz body'; }

status=$(curl --silent --output "$work/root.html" --write-out '%{http_code}' --max-time 10 "$base/")
[ "$status" = 200 ] || fail "SPA root returned $status, want 200"
grep -qi '<!doctype html>' "$work/root.html" || { head -c 300 "$work/root.html" >&2; fail 'SPA root is not HTML'; }

curl --fail --silent --max-time 10 "$base/api/v1/settings" >"$work/settings.json" ||
  fail '/api/v1/settings request failed'
grep -q "\"Version\":\"$expected_version\"" "$work/settings.json" || {
  cat "$work/settings.json" >&2
  fail 'settings do not report the expected UI version'
}
grep -q '"DefaultNamespace":"default"' "$work/settings.json" || fail 'settings lack the default namespace'

# Backend calls fail with a service error, not a crash, when no Temporal server is reachable.
status=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 20 "$base/api/v1/namespaces")
case "$status" in
  5??) ;;
  *) fail "namespace listing without a backend returned $status, want a 5xx" ;;
esac
curl --fail --silent --max-time 5 "$base/healthz" >/dev/null || fail 'ui died after a backend error'

# SIGTERM stops the server promptly. ui-server installs no handler of its own: as PID 1 the Go
# runtime cannot re-raise the signal, so it exits 2; 0 or 143 are accepted for other runtimes.
# 137 would mean it ignored SIGTERM and was killed after the grace period.
started=$(date +%s)
docker stop -t 20 "$container" >/dev/null
[ $(($(date +%s) - started)) -lt 15 ] || fail 'ui-server took too long to stop on SIGTERM'
code=$(docker inspect -f '{{.State.ExitCode}}' "$container")
case "$code" in
  0|2|143) ;;
  *) fail "ui-server exited with $code on SIGTERM" ;;
esac

printf 'SMOKE PASS image=%s\n' "$image"
