#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-pyroscope-test-$$"
volume="verity-pyroscope-data-$$"
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
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/pyroscope"]' ] \
  || fail 'unexpected image entrypoint'
[ "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["-config.file=/etc/pyroscope/config.yaml"]' ] \
  || fail 'unexpected image command'
docker run --rm "$image" -version 2>&1 | grep -F 'version 2.4.' >/dev/null \
  || fail 'pyroscope version check failed'
docker run --rm --entrypoint /usr/bin/profilecli "$image" --help 2>&1 | grep -F 'usage' >/dev/null \
  || fail 'profilecli is missing'

# Negative case: an unusable config must exit non-zero with a readable error.
printf 'server:\n  http_listen_port: not-a-port\n' >"$tmp/bad.yaml"
chmod 644 "$tmp/bad.yaml"
if docker run --rm -v "$tmp/bad.yaml:/tmp/bad.yaml:ro" "$image" \
  -config.file=/tmp/bad.yaml >"$tmp/bad.log" 2>&1; then
  fail 'pyroscope accepted an invalid configuration'
fi
grep -Eqi 'error|invalid|failed|cannot' "$tmp/bad.log" \
  || { cat "$tmp/bad.log" >&2; fail 'invalid config error was not readable'; }

docker volume create "$volume" >/dev/null
docker run --name "$container" -d --read-only --tmpfs /tmp:uid=10001,gid=10001,mode=1777 \
  -v "$volume:/data" \
  -p 127.0.0.1::4040 \
  "$image" >/dev/null
port=$(docker port "$container" 4040/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || fail 'pyroscope port was not published'
base="http://127.0.0.1:$port"

attempt=0
until response=$(curl --fail --silent --connect-timeout 1 --max-time 5 "$base/ready"); do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 120 ] || fail 'pyroscope did not become ready'
  sleep 1
done
printf '%s' "$response" | grep -F ready >/dev/null || fail 'pyroscope readiness response was unexpected'

# The embedded web UI is served from the binary.
curl --fail --silent --max-time 5 "$base/" | grep -Fi '<html' >/dev/null \
  || fail 'embedded web UI was not served'

# Ingest one folded profile, then read it back through the render API. Ingested
# data becomes queryable after the segment writer flushes, about a minute.
now=$(date +%s)
printf 'main;work;compute 70\nmain;work;io 30\n' >"$tmp/profile.folded"
curl --fail --silent --show-error --max-time 10 -X POST \
  --data-binary "@$tmp/profile.folded" \
  "$base/ingest?name=verity_smoke.cpu&from=$((now - 10))&until=$now&format=folded" \
  || fail 'profile ingest failed'

attempt=0
query='process_cpu:cpu:nanoseconds:cpu:nanoseconds%7Bservice_name%3D%22verity_smoke%22%7D'
until curl --fail --silent --max-time 10 \
  "$base/pyroscope/render?query=$query&from=now-5m&until=now&format=collapsed" \
  >"$tmp/render.json" 2>/dev/null && grep -F compute "$tmp/render.json" >/dev/null; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 120 ]; then
    cat "$tmp/render.json" >&2 || true
    fail 'ingested profile was not readable through /pyroscope/render'
  fi
  sleep 2
done

# SIGTERM must stop the server cleanly. The segment writer drains for about 30
# seconds before exiting, so allow more than the default grace period.
docker stop --timeout 120 "$container" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ] \
  || fail 'pyroscope did not exit cleanly on SIGTERM'
