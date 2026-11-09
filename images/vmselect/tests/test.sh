#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
# Repository vmstorage and vminsert images complete the cluster fixture.
vmstorage_index='ghcr.io/tektum/vmstorage@sha256:358dde467b1bcf3f716cc09ee2f451012643f1f48f356baecfc425e437077b0a'
vminsert_index='ghcr.io/tektum/vminsert@sha256:16d133e36f433021c1186951928feebbb1fb5da45301063f305a67b8cef92c2b'
label=verity.test=vmselect-$$
network="verity-vmselect-network-$$"
volume="verity-vmselect-storage-$$"
storage="verity-vmselect-storage-$$"
insert="verity-vmselect-insert-$$"
select="verity-vmselect-select-$$"

fail() {
  for name in "$storage" "$insert" "$select"; do
    printf -- '--- %s\n' "$name" >&2
    docker logs "$name" >&2 2>&1 || true
  done
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$select" "$insert" "$storage" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 10001 ] \
  || fail 'image user is not 10001'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/vmselect"]' ] \
  || fail 'unexpected image entrypoint'
[ "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["-cacheDataPath=/vmselect-cache"]' ] \
  || fail 'unexpected image command'
docker run --rm "$image" -version 2>&1 | grep -F 'vmselect-tags-v1.' >/dev/null \
  || fail 'vmselect version check failed'

# pull_child INDEX: pull the pinned index by its per-platform child digest,
# verifying the index bytes against the pin first so the pin stays authoritative.
image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
pull_child() {
  raw=$(docker buildx imagetools inspect --raw "$1") || fail "cannot inspect $1"
  [ "sha256:$(printf '%s' "$raw" | sha256sum | cut -d' ' -f1)" = "${1#*@}" ] \
    || fail "index digest mismatch for $1"
  child=$(printf '%s' "$raw" | jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') || fail "cannot resolve a child of $1"
  case $child in
    sha256:*) ;;
    *) fail "no unique linux/$image_arch child in $1" ;;
  esac
  docker pull --quiet --platform "linux/$image_arch" "${1%%@*}@$child" >/dev/null \
    || fail "cannot pull ${1%%@*}@$child"
  printf '%s' "${1%%@*}@$child"
}
vmstorage_image=$(pull_child "$vmstorage_index")
vminsert_image=$(pull_child "$vminsert_index")

docker network create --label "$label" "$network" >/dev/null
docker volume create --label "$label" "$volume" >/dev/null

wait_health() {
  attempt=0
  until response=$(curl --fail --silent --connect-timeout 1 --max-time 5 "http://127.0.0.1:$2/health"); do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 30 ] || fail "$1 did not become healthy"
    sleep 1
  done
  [ "$response" = OK ] || fail "$1 health response was not OK"
}

published() {
  value=$(docker port "$1" "$2/tcp" | awk -F: 'NR == 1 { print $2 }')
  [ -n "$value" ] || fail "port $2 of $1 was not published"
  printf '%s' "$value"
}

# A single-node cluster: vminsert writes to vmstorage, vmselect reads from it.
docker run --name "$storage" -d --label "$label" --network "$network" --read-only \
  -v "$volume:/vmstorage-data" "$vmstorage_image" >/dev/null
docker run --name "$insert" -d --label "$label" --network "$network" --read-only \
  -p 127.0.0.1::8480 "$vminsert_image" "-storageNode=$storage:8400" >/dev/null
docker run --name "$select" -d --label "$label" --network "$network" --read-only \
  -p 127.0.0.1::8481 "$image" "-storageNode=$storage:8401" \
  -cacheDataPath=/vmselect-cache >/dev/null
insert_port=$(published "$insert" 8480)
select_port=$(published "$select" 8481)
wait_health vminsert "$insert_port"
wait_health vmselect "$select_port"

curl --fail --silent --show-error -X POST \
  "http://127.0.0.1:$insert_port/insert/0/prometheus/api/v1/import/prometheus" \
  --data-binary "verity_smoke_metric{job=\"verity\"} 42 $(( $(date +%s) - 120 ))000" >/dev/null \
  || fail 'sample import through vminsert failed'
attempt=0
until curl --fail --silent --show-error --get \
  "http://127.0.0.1:$select_port/select/0/prometheus/api/v1/query" \
  --data-urlencode 'query=verity_smoke_metric' | grep -F '"42"' >/dev/null; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 30 ] || fail 'sample ingested through vminsert was not queryable through vmselect'
  sleep 1
done

# A different tenant must not see the sample.
curl --fail --silent --show-error --get \
  "http://127.0.0.1:$select_port/select/1/prometheus/api/v1/query" \
  --data-urlencode 'query=verity_smoke_metric' | grep -F '"result":[]' >/dev/null \
  || fail 'tenant isolation did not hold'

docker stop --time 30 "$select" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$select")" = 0 ] \
  || fail 'vmselect did not stop cleanly'

# Without a reachable vmstorage vmselect still starts and reports healthy.
docker rm "$select" >/dev/null
docker run --name "$select" -d --label "$label" --read-only -p 127.0.0.1::8481 "$image" \
  -storageNode=127.0.0.1:1 -cacheDataPath=/vmselect-cache >/dev/null
wait_health vmselect "$(published "$select" 8481)"
docker rm -f "$select" >/dev/null

if invalid=$(docker run --rm "$image" -no-such-flag 2>&1); then
  fail 'invalid flag unexpectedly succeeded'
fi
printf '%s' "$invalid" | grep -Fi 'flag provided but not defined' >/dev/null \
  || fail 'invalid flag did not return a readable error'

printf 'SMOKE PASS image=%s\n' "$image"
