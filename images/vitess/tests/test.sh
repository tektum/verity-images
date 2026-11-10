#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml" | sed -n 1p)
[ -n "$version" ] || { printf 'package version not found\n' >&2; exit 1; }
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
  --cell=zone1 --topo-implementation=etcd2 --topo-global-server-address=127.0.0.1:2379 \
  --topo-global-root=/vitess/global --tablet-types-to-wait=PRIMARY --port=15001 \
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
if grep -Ei 'unknown flag|invalid argument' "$work/vtgate" >/dev/null; then
  fail 'vtgate rejected its flags before reaching topo'
fi
grep -F 'Failed to open topo server (etcd2,127.0.0.1:2379,/vitess/global)' "$work/vtgate" >/dev/null ||
  fail 'vtgate did not report the unreachable topo'

printf 'SMOKE PASS image=%s\n' "$image"
