#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)"$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
container="verity-etcd-test-$$"
volume="verity-etcd-data-$$"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  docker logs "$container" >&2 2>/dev/null || true
  printf '%s\n' "$1" >&2
  exit 1
}

test "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532
test "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/etcd"]'

docker run --rm --entrypoint /bin/sh --env expected_version="$expected_version" "$image" -c '
  set -eu
  test -x /usr/bin/etcd
  test -x /usr/bin/etcdctl
  test -x /usr/bin/etcdutl
  test -L /usr/local/bin/etcd
  [ "$(readlink /usr/local/bin/etcd)" = "../../bin/etcd" ]
  [ "$(stat -c "%u:%g:%a" /var/lib/etcd)" = "65532:65532:700" ]
  /usr/local/bin/etcd --version | grep -F "etcd Version: $expected_version"
  # etcdutl-only subcommand: guards against etcdutl being built from the
  # etcdctl module (that regressed once; etcdctl has no hashkv).
  /usr/bin/etcdutl --help | grep -q hashkv
' || fail 'image contract inspection failed'

docker volume create "$volume" >/dev/null

start() {
  docker run --name "$container" -d \
    -v "$volume:/var/lib/etcd" \
    -p 127.0.0.1::2379 -p 127.0.0.1::2380 \
    "$image" \
    --data-dir /var/lib/etcd/default.etcd \
    --listen-client-urls http://0.0.0.0:2379 \
    --advertise-client-urls http://127.0.0.1:2379 \
    --listen-peer-urls http://0.0.0.0:2380 \
    --initial-advertise-peer-urls http://127.0.0.1:2380 \
    --initial-cluster "default=http://127.0.0.1:2380" >/dev/null
  client_port=$(docker port "$container" 2379/tcp | awk -F: 'NR == 1 { print $2 }')
  peer_port=$(docker port "$container" 2380/tcp | awk -F: 'NR == 1 { print $2 }')
  [ -n "$client_port" ] && [ -n "$peer_port" ] || fail 'client port 2379 and peer port 2380 were not published'

  attempts=0
  until docker exec "$container" etcdctl endpoint health >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 30 ] || fail 'etcd did not become healthy'
    sleep 1
  done
}

start

peer_probe=$(curl --verbose --connect-timeout 2 --max-time 3 "http://127.0.0.1:$peer_port/" 2>&1 || true)
printf '%s\n' "$peer_probe" | grep -Fq 'Connected to 127.0.0.1' || fail 'peer listener is not accepting connections on port 2380'

docker exec "$container" etcdctl put verity-smoke 'Hello, etcd' >/dev/null
result=$(docker exec "$container" etcdctl get verity-smoke --print-value-only)
test "$result" = 'Hello, etcd' || fail 'put/get roundtrip failed'

docker rm -f "$container" >/dev/null

start

result=$(docker exec "$container" etcdctl get verity-smoke --print-value-only)
test "$result" = 'Hello, etcd' || fail 'data did not survive restart'

if error=$(docker exec "$container" etcdctl --endpoints=http://127.0.0.1:1 --dial-timeout=2s get verity-smoke 2>&1); then
  printf '%s\n' 'bad endpoint unexpectedly succeeded' >&2
  exit 1
fi
printf '%s\n' "$error" | grep -Eqi 'context deadline exceeded|connection refused' || fail 'bad endpoint did not return the documented connection error'

printf 'SMOKE PASS image=%s\n' "$image"
