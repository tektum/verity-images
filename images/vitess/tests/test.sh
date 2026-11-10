#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
version=24.0.5
work=$(mktemp -d)

trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 1000 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'

for bin in vtgate vtctld vttablet vtctldclient vtctlclient vtorc mysqlctl vtbackup; do
  docker run --rm --network none --read-only --entrypoint "/usr/bin/$bin" "$image" --version \
    >"$work/$bin.version" 2>&1 || fail "$bin --version failed"
  grep -F "$version" "$work/$bin.version" >/dev/null || fail "$bin version is not $version"
done

docker run --rm --network none --read-only --entrypoint /usr/bin/vtctldclient "$image" --help \
  >"$work/help" 2>&1 || fail 'vtctldclient --help failed'
grep -F 'Available Commands' "$work/help" >/dev/null || fail 'vtctldclient help is missing commands'

# vtgate with an unreachable topo must fail with an explicit error, not hang.
rc=0
docker run --rm --network none --read-only --label verity-test=vitess "$image" \
  --cell=zone1 --topo_implementation=etcd2 --topo_global_server_address=127.0.0.1:2379 \
  --topo_global_root=/vitess/global --tablet_types_to_wait=PRIMARY --port=15001 \
  >"$work/vtgate" 2>&1 &
pid=$!
n=0
while kill -0 "$pid" 2>/dev/null; do
  n=$((n + 1))
  if [ "$n" -gt 90 ]; then
    kill "$pid" 2>/dev/null || true
    docker ps -q --filter label=verity-test=vitess | xargs -r docker kill >/dev/null
    fail 'vtgate hung without a reachable topo'
  fi
  sleep 1
done
wait "$pid" || rc=$?
test "$rc" -ne 0 || fail 'vtgate unexpectedly succeeded without topo'
grep -Ei 'error|fail|topo' "$work/vtgate" >/dev/null || fail 'vtgate gave no explicit error'

printf 'SMOKE PASS image=%s\n' "$image"
