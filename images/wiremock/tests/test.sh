#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE [FLAVOR]}
flavor=${2:-plain}
recipe="$(dirname "$0")/../melange.yaml"
version=$(sed -n 's/^  version: "\([0-9.]*\)".*$/\1/p' "$recipe")
label="verity-test=wiremock-$$"
name="verity-wiremock-$$"
work=$(mktemp -d)

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -f >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

dump() {
  printf '== logs: %s\n' "$name" >&2
  docker logs "$name" >&2 2>&1 || true
}

case $flavor in plain) ;; *) fail "unsupported flavor $flavor" ;; esac
[ -n "$version" ] || fail 'could not read the recipe version'

# OCI contract: non-root user and the upstream home directory layout.
test "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 || fail 'unexpected OCI user'
test "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /home/wiremock ||
  fail 'unexpected working directory'

# The CLI reports the recipe version.
out=$(docker run --rm --label "$label" --network none "$image" --version 2>&1) ||
  { printf '%s\n' "$out" >&2; fail '--version failed'; }
printf '%s\n' "$out" | grep -qx "$version" || { printf '%s\n' "$out" >&2; fail "not WireMock $version"; }

# Negative: an unknown option makes WireMock exit non-zero.
rc=0
timeout 120 docker run --rm --label "$label" --network none "$image" --no-such-option \
  >"$work/bad.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'WireMock accepted an unknown option'
[ "$rc" -ne 124 ] || fail 'WireMock hung on an unknown option'

docker run -d --name "$name" --label "$label" -p 127.0.0.1::8080 "$image" --disable-banner >/dev/null
port=$(docker port "$name" 8080/tcp | head -n1 | sed 's/.*://')
[ -n "$port" ] || fail 'no published port'
base="http://127.0.0.1:$port"

i=0
until curl -fsS -m 5 "$base/__admin/health" >"$work/health.json" 2>/dev/null; do
  i=$((i + 1))
  [ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ] || { dump; fail 'WireMock exited early'; }
  [ "$i" -le 90 ] || { dump; fail 'WireMock did not become ready'; }
  sleep 2
done
jq -e --arg v "$version" '.status == "healthy" and .version == $v' "$work/health.json" >/dev/null ||
  { cat "$work/health.json" >&2; fail 'health endpoint is not healthy or reports the wrong version'; }

# Register a stub through the admin API, then call it.
curl -fsS -m 10 -X POST -H 'Content-Type: application/json' "$base/__admin/mappings" -d '{
  "request": {"method": "GET", "urlPath": "/verity/ping", "queryParameters": {"who": {"equalTo": "smoke"}}},
  "response": {"status": 200, "jsonBody": {"pong": "smoke"}, "headers": {"Content-Type": "application/json"}}
}' >/dev/null || { dump; fail 'cannot create a stub mapping'; }
curl -fsS -m 10 "$base/verity/ping?who=smoke" >"$work/pong.json" || { dump; fail 'stub did not match'; }
jq -e '.pong == "smoke"' "$work/pong.json" >/dev/null || { cat "$work/pong.json" >&2; fail 'unexpected stub body'; }

# Negative: an unmatched request returns 404, and the request journal records both calls.
code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$base/verity/ping?who=other")
[ "$code" = 404 ] || fail "unmatched request returned $code, not 404"
curl -fsS -m 10 "$base/__admin/requests" >"$work/requests.json" || fail 'cannot read the request journal'
jq -e '[.requests[] | select(.request.url | startswith("/verity/ping"))] | length == 2' "$work/requests.json" \
  >/dev/null || { cat "$work/requests.json" >&2; fail 'request journal does not record both calls'; }

# SIGTERM: the JVM is PID 1 and must shut down on its own.
docker kill --signal TERM "$name" >/dev/null
i=0
while [ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ]; do
  i=$((i + 1))
  [ "$i" -le 30 ] || { dump; fail 'WireMock did not stop within 30s of SIGTERM'; }
  sleep 1
done
rc=$(docker inspect -f '{{.State.ExitCode}}' "$name")
case $rc in
  0 | 143) ;;
  *) dump; fail "WireMock exited with $rc after SIGTERM" ;;
esac

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$version"
