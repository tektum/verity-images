#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# etcdctl from the Verity etcd image, pinned by digest.
etcd_index=ghcr.io/tektum/etcd@sha256:fc322841b20ac374159333e013fb417aa712e776380c53dc34ab8a1958c07fd2

id=$$
network="verity-kine-$id"
kine="verity-kine-$id"
volume="verity-kine-db-$id"
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  docker logs "$kine" 2>&1 | tail -n 40 >&2 || true
  exit 1
}

cleanup() {
  docker rm -f "$kine" >/dev/null 2>&1 || true
  docker volume rm "$volume" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'

test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/kine"]' ||
  fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 || fail 'unexpected OCI user'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = / ||
  fail 'unexpected working directory'

version=$(docker run --rm --network none "$image" --version) || fail 'kine --version failed'
case $version in
  "kine version v$expected_version ("*) ;;
  *) fail "unexpected version: $version" ;;
esac

# pull_child INDEX: pull the pinned index by its per-platform child digest,
# verifying the index bytes against the pin first so the pin stays authoritative.
image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
pull_child() {
  raw=$(docker buildx imagetools inspect --raw "$1") || fail "cannot inspect $1"
  [ "sha256:$(printf '%s' "$raw" | sha256sum | cut -d' ' -f1)" = "${1#*@}" ] ||
    fail "index digest mismatch for $1"
  child=$(printf '%s' "$raw" | jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') || fail "cannot resolve a child of $1"
  case $child in
    sha256:*) ;;
    *) fail "no unique linux/$image_arch child in $1" ;;
  esac
  docker pull --quiet --platform "linux/$image_arch" "${1%%@*}@$child" >/dev/null ||
    fail "cannot pull ${1%%@*}@$child"
  printf '%s' "${1%%@*}@$child"
}
etcd_image=$(pull_child "$etcd_index")

etcdctl() {
  docker run --rm -i --network "$network" --entrypoint /usr/bin/etcdctl \
    "$etcd_image" --endpoints="http://$kine:2379" --command-timeout=10s "$@"
}

# start_kine: serve the etcd API from the default SQLite database in /db, on a
# read-only root filesystem with no capabilities.
start_kine() {
  docker run -d --name "$kine" --network "$network" --read-only --cap-drop=ALL \
    --security-opt no-new-privileges -v "$volume:/db" "$image" >/dev/null
  i=0
  until etcdctl get /verity-smoke-ready >/dev/null 2>&1; do
    [ "$(docker inspect --format '{{.State.Running}}' "$kine")" = true ] || fail 'kine exited'
    i=$((i + 1))
    [ "$i" -lt 30 ] || fail 'kine did not become healthy'
    sleep 1
  done
}

docker network create "$network" >/dev/null
docker volume create "$volume" >/dev/null
start_kine
docker logs "$kine" 2>&1 | grep -F "Kine built with sqlite from github.com/mattn/go-sqlite3 version" >/dev/null ||
  fail 'kine did not serve from the cgo SQLite backend'

# Round-trip keys through the etcd v3 API.
etcdctl put /registry/smoke/alpha one >/dev/null || fail 'put alpha failed'
etcdctl put /registry/smoke/beta two >/dev/null || fail 'put beta failed'
etcdctl put /registry/other/gamma three >/dev/null || fail 'put gamma failed'
test "$(etcdctl get /registry/smoke/alpha --print-value-only)" = one || fail 'get alpha returned the wrong value'
printf '/registry/smoke/alpha\none\n/registry/smoke/beta\ntwo\n' >"$work/want"
etcdctl get /registry/smoke/ --prefix >"$work/got" || fail 'prefix get failed'
cmp -s "$work/want" "$work/got" || fail "prefix get returned: $(cat "$work/got")"
test "$(etcdctl get /registry/smoke/ --prefix --count-only --write-out=fields |
  awk -F' : ' '$1 == "\"Count\"" { print $2 }')" = 2 || fail 'prefix count is not 2'

# mod_revision of KEY.
mod_rev() {
  etcdctl get "$1" --write-out=fields | awk -F' : ' '$1 == "\"ModRevision\"" { print $2 }'
}

# Kine serves the transaction shapes the Kubernetes API server issues instead
# of plain DeleteRange: guarded create, update, and delete.
# txn COMPARE SUCCESS FAILURE prints SUCCESS or FAILURE.
txn() {
  printf '%s\n\n%s\n\n%s\n\n' "$1" "$2" "$3" | etcdctl txn | head -n 1
}

# Guarded create succeeds once and never overwrites.
test "$(txn 'mod("/registry/smoke/created") = "0"' 'put /registry/smoke/created first' '')" = SUCCESS ||
  fail 'create transaction did not succeed'
test "$(txn 'mod("/registry/smoke/created") = "0"' 'put /registry/smoke/created second' '')" = FAILURE ||
  fail 'duplicate create transaction did not fail'
test "$(etcdctl get /registry/smoke/created --print-value-only)" = first ||
  fail 'duplicate create overwrote the key'

# Guarded update at the current revision moves it forward; a stale revision
# is refused. A watch from the old revision replays the change.
rev=$(mod_rev /registry/smoke/alpha)
[ -n "$rev" ] || fail 'alpha has no mod revision'
test "$(txn "mod(\"/registry/smoke/alpha\") = \"$rev\"" 'put /registry/smoke/alpha uno' \
  'get /registry/smoke/alpha')" = SUCCESS || fail 'update alpha failed'
test "$(etcdctl get /registry/smoke/alpha --print-value-only)" = uno || fail 'update did not take effect'
test "$(mod_rev /registry/smoke/alpha)" -gt "$rev" || fail 'update did not move the revision forward'
test "$(txn "mod(\"/registry/smoke/alpha\") = \"$rev\"" 'put /registry/smoke/alpha stale' \
  'get /registry/smoke/alpha')" = FAILURE || fail 'stale update was not refused'
test "$(etcdctl get /registry/smoke/alpha --print-value-only)" = uno || fail 'stale update took effect'
etcdctl watch /registry/smoke/alpha --rev="$rev" >"$work/watch" 2>&1 &
watcher=$!
i=0
until grep -Fx uno "$work/watch" >/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 20 ] || { kill "$watcher" 2>/dev/null || true; fail "watch did not replay: $(cat "$work/watch")"; }
  sleep 1
done
kill "$watcher" 2>/dev/null || true
wait "$watcher" 2>/dev/null || true

# Guarded delete removes the key.
rev=$(mod_rev /registry/smoke/beta)
test "$(txn "mod(\"/registry/smoke/beta\") = \"$rev\"" 'del /registry/smoke/beta' \
  'get /registry/smoke/beta')" = SUCCESS || fail 'delete beta failed'
test -z "$(etcdctl get /registry/smoke/beta)" || fail 'beta survived deletion'

# The keys live in SQLite on the volume and survive a restart.
docker rm -f "$kine" >/dev/null
docker run --rm -v "$volume:/db:ro" --entrypoint /bin/sh "$etcd_image" -c \
  'test -s /db/state.db && head -c 15 /db/state.db' | grep -Fx 'SQLite format 3' >/dev/null ||
  fail 'state.db is not a SQLite database'
start_kine
test "$(etcdctl get /registry/smoke/alpha --print-value-only)" = uno || fail 'alpha did not persist'
test "$(etcdctl get /registry/other/gamma --print-value-only)" = three || fail 'gamma did not persist'
test -z "$(etcdctl get /registry/smoke/beta)" || fail 'deleted beta reappeared'

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$expected_version"
