#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf '%s\n' 'package version not found' >&2; exit 1; }
suffix="$$-$(date +%s)"
network="verity-chisel-test-$suffix"
server="verity-chisel-server-$suffix"
client="verity-chisel-client-$suffix"
badclient="verity-chisel-badclient-$suffix"

cleanup() {
  docker rm -f "$server" "$client" "$badclient" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  for c in "$server" "$client" "$badclient"; do
    docker logs "$c" >&2 2>&1 || true
  done
  exit 1
}

user=$(docker image inspect -f '{{.Config.User}}' "$image")
[ "$user" = 65532 ] || fail "image user is $user, want 65532"
entrypoint=$(docker image inspect -f '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' "$image")
[ "$entrypoint" = '["/usr/bin/chisel"] null' ] || fail "unexpected entrypoint: $entrypoint"
[ "$(docker run --rm "$image" --version)" = "$expected_version" ] ||
  fail "unexpected version, want $expected_version"
if docker run --rm "$image" server --no-such-flag >/dev/null 2>&1; then
  fail 'unknown flag was accepted'
fi

docker network create --label verity-test=chisel "$network" >/dev/null

docker run -d --name "$server" --label verity-test=chisel --network "$network" \
  --read-only "$image" server --port 8080 --auth verity:s3cret >/dev/null

# The client forwards its port 3000 through the SSH-over-HTTP tunnel to the
# server's own HTTP listener, whose /version endpoint returns the build version.
docker run -d --name "$client" --label verity-test=chisel --network "$network" \
  --read-only -p 127.0.0.1::3000 "$image" \
  client --auth verity:s3cret "http://$server:8080" 0.0.0.0:3000:127.0.0.1:8080 >/dev/null
port=$(docker port "$client" 3000/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || fail 'no published host port'

attempts=0
until body=$(curl --fail --silent --connect-timeout 1 --max-time 5 "http://127.0.0.1:$port/version"); do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || fail 'tunnel did not become ready'
  sleep 1
done
[ "$body" = "$expected_version" ] || fail "unexpected tunneled body: $body"
[ "$(curl --fail --silent --max-time 5 "http://127.0.0.1:$port/health")" = OK ] ||
  fail 'tunneled /health did not return OK'
docker logs "$client" 2>&1 | grep -F 'Connected' >/dev/null || fail 'client did not log a connection'

# Wrong credentials are rejected by the server.
docker run -d --name "$badclient" --label verity-test=chisel --network "$network" \
  --read-only "$image" \
  client --max-retry-count 0 --auth verity:wrong "http://$server:8080" 3001:127.0.0.1:8080 >/dev/null
attempts=0
while [ "$(docker inspect -f '{{.State.Running}}' "$badclient")" = true ]; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || fail 'client with wrong credentials kept running'
  sleep 1
done
[ "$(docker inspect -f '{{.State.ExitCode}}' "$badclient")" != 0 ] ||
  fail 'client with wrong credentials exited 0'
docker logs "$badclient" 2>&1 | grep -Ei 'authentication failed|unable to authenticate' >/dev/null ||
  fail 'client with wrong credentials did not report an authentication failure'

printf '%s\n' "chisel $expected_version smoke test passed"
