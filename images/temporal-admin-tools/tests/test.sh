#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)"$/\1/p' \
  "$(dirname "$0")/../melange.yaml" | sed -n 1p)
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
container="verity-temporal-admin-tools-test-$$"
tmp=$(mktemp -d)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  docker logs "$container" >&2 2>&1 || true
  exit 1
}

[ "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532 ] ||
  fail 'unexpected image config: User'

tdbg_version=$(docker run --rm --network none "$image" tdbg --version)
case "$tdbg_version" in
  *"$expected_version"*) ;;
  *) fail "tdbg version $tdbg_version does not contain $expected_version" ;;
esac
docker run --rm --network none "$image" temporal-sql-tool --help >/dev/null ||
  fail 'temporal-sql-tool --help failed'
docker run --rm --network none "$image" temporal-cassandra-tool --help >/dev/null ||
  fail 'temporal-cassandra-tool --help failed'
docker run --rm --network none "$image" test -f /etc/temporal/schema/mysql/v8/temporal/schema.sql ||
  fail 'bundled mysql schema missing'

docker run --name "$container" -d --read-only --tmpfs /tmp:uid=65532,gid=65532 \
  "$image" temporal server start-dev --ip 127.0.0.1 --headless >/dev/null
attempts=0
until docker exec "$container" temporal operator namespace list >"$tmp/ns.txt" 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || fail 'temporal dev server did not become ready'
  sleep 1
done
grep -qw default "$tmp/ns.txt" || { cat "$tmp/ns.txt" >&2; fail 'default namespace not listed'; }
if docker exec "$container" tdbg --address 127.0.0.1:7233 --namespace default \
  workflow describe --workflow-id verity-missing >"$tmp/tdbg.txt" 2>&1; then
  fail 'tdbg describe of a missing workflow unexpectedly succeeded'
fi
grep -qi 'not found' "$tmp/tdbg.txt" || { cat "$tmp/tdbg.txt" >&2; fail 'tdbg did not reach the server'; }

if docker exec "$container" temporal operator namespace describe --namespace missing-ns \
  >"$tmp/missing.log" 2>&1; then
  fail 'describing a missing namespace unexpectedly succeeded'
fi
grep -qi 'not found\|missing-ns' "$tmp/missing.log" || {
  cat "$tmp/missing.log" >&2
  fail 'missing namespace error is not readable'
}

printf 'SMOKE PASS image=%s\n' "$image"
