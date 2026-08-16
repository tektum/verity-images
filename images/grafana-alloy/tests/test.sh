#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-grafana-alloy-test-$$"
fixture=$(mktemp -d)

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$fixture"
}
trap cleanup EXIT INT TERM

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 473 ] ||
  fail 'image user is not 473'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/alloy"]' ] || fail 'unexpected image entrypoint'
[ "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = \
  '["run","/etc/alloy/config.alloy","--storage.path=/var/lib/alloy/data"]' ] ||
  fail 'unexpected image command'
version_output=$(docker run --rm --cpus 4 --entrypoint /usr/bin/alloy "$image" --version 2>&1) ||
  fail "alloy version command failed: $version_output"
printf '%s\n' "$version_output" | grep -F '1.18.1' >/dev/null ||
  fail "alloy version check failed: $version_output"

docker run --name "$container" -d --read-only --cpus 4 \
  --tmpfs /var/lib/alloy/data:uid=473,gid=473,mode=0770 \
  -p 127.0.0.1::12345 "$image" \
  run /etc/alloy/config.alloy --storage.path=/var/lib/alloy/data \
  --server.http.listen-addr=0.0.0.0:12345 >/dev/null
port=$(docker port "$container" 12345/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || fail 'Alloy HTTP port was not published'

i=0
until curl --fail --silent --connect-timeout 1 --max-time 2 \
  "http://127.0.0.1:$port/-/ready" >/dev/null; do
  [ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ] || {
    docker logs "$container" >&2
    fail 'Alloy exited before becoming ready'
  }
  i=$((i + 1))
  [ "$i" -lt 30 ] || {
    docker logs "$container" >&2
    fail 'Alloy did not become ready'
  }
  sleep 1
done
curl --fail --silent --max-time 5 "http://127.0.0.1:$port/" |
  grep -F '<title>Grafana Alloy</title>' >/dev/null || fail 'embedded Alloy UI was not served'
docker stop --time 30 "$container" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ] ||
  fail 'Alloy did not stop cleanly'
docker rm "$container" >/dev/null

printf '%s\n' 'logging {' '  level = ' '}' >"$fixture/invalid.alloy"
chmod 644 "$fixture/invalid.alloy"
if output=$(docker run --rm --read-only --cpus 4 \
  --tmpfs /var/lib/alloy/data:uid=473,gid=473,mode=0770 \
  -v "$fixture/invalid.alloy:/etc/alloy/config.alloy:ro" "$image" 2>&1); then
  fail 'invalid Alloy config unexpectedly succeeded'
fi
printf '%s\n' "$output" | grep -F 'config.alloy' >/dev/null ||
  fail 'invalid Alloy config failure did not identify the config file'

printf 'SMOKE PASS image=%s\n' "$image"
