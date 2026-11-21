#!/bin/sh
set -eu

# The cluster peer runs without an IPFS daemon and with --network none; the
# REST API is exercised through ipfs-cluster-ctl inside the same container.
image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^  version: "\([0-9][0-9.]*\)".*/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf '%s\n' 'ipfs-cluster melange version not found' >&2; exit 1; }
label="verity-test-ipfs-cluster-$$"
volume="$label"
container=

cleanup() {
  [ -z "$container" ] || docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [ -z "$container" ] || docker logs "$container" >&2 2>&1 || true
  exit 1
}

inspect() {
  docker image inspect -f "$1" "$image"
}

[ "$(inspect '{{.Config.User}}')" = 65532 ] || fail "image user is $(inspect '{{.Config.User}}'), want 65532"
[ "$(inspect '{{json .Config.Entrypoint}} {{json .Config.Cmd}}')" = '["/usr/local/bin/entrypoint.sh"] ["daemon"]' ] ||
  fail "unexpected entrypoint: $(inspect '{{json .Config.Entrypoint}} {{json .Config.Cmd}}')"
[ "$(inspect '{{.Config.WorkingDir}}')" = /data/ipfs-cluster ] || fail 'unexpected working directory'
[ "$(inspect '{{json .Config.Volumes}}')" = '{"/data/ipfs-cluster":{}}' ] ||
  fail "unexpected volumes: $(inspect '{{json .Config.Volumes}}')"
env=$(inspect '{{range .Config.Env}}{{println .}}{{end}}')
printf '%s\n' "$env" | grep -Fx 'IPFS_CLUSTER_PATH=/data/ipfs-cluster' >/dev/null || fail 'IPFS_CLUSTER_PATH is not set'
printf '%s\n' "$env" | grep -Fx 'IPFS_CLUSTER_CONSENSUS=crdt' >/dev/null || fail 'IPFS_CLUSTER_CONSENSUS is not crdt'

for tool in ipfs-cluster-service ipfs-cluster-ctl ipfs-cluster-follow; do
  out=$(docker run --rm --network none --entrypoint "/usr/bin/$tool" "$image" --version 2>&1) ||
    fail "$tool --version failed: $out"
  printf '%s\n' "$out" | grep -F "$expected_version" >/dev/null || fail "unexpected $tool version: $out"
done

docker volume create --label "$label" "$volume" >/dev/null

start_peer() {
  container=$(docker run -d --label "$label" --network none -v "$volume:/data/ipfs-cluster" "$image")
  attempts=0
  until docker exec "$container" ipfs-cluster-ctl --enc json id >/tmp/"$label".id 2>/dev/null; do
    [ "$(docker inspect -f '{{.State.Running}}' "$container")" = true ] || fail 'cluster peer exited'
    attempts=$((attempts + 1))
    [ "$attempts" -lt 60 ] || fail 'cluster REST API did not become ready'
    sleep 1
  done
  peer_id=$(sed -n 's/.*"id": *"\([^"]*\)".*/\1/p' /tmp/"$label".id | head -n1)
  rm -f /tmp/"$label".id
  [ -n "$peer_id" ] || fail 'ipfs-cluster-ctl id returned no peer id'
}

start_peer
first_id=$peer_id
docker logs "$container" 2>&1 | grep -F 'Initializing default configuration' >/dev/null ||
  fail 'entrypoint did not initialize a default configuration'
for file in service.json identity.json; do
  docker exec "$container" test -s "/data/ipfs-cluster/$file" || fail "$file was not written to the volume"
done
docker exec "$container" grep -F '"crdt"' /data/ipfs-cluster/service.json >/dev/null ||
  fail 'service.json does not configure crdt consensus'

# Pinning without an IPFS daemon is accepted into the shared pinset; the
# allocation then reports the IPFS connector error rather than succeeding.
cid=bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi
docker exec "$container" ipfs-cluster-ctl pin add --no-status "$cid" >/dev/null ||
  fail 'pin add was rejected'
docker exec "$container" ipfs-cluster-ctl pin ls "$cid" | grep -F "$cid" >/dev/null ||
  fail 'pinned CID is missing from the pinset'
if docker exec "$container" ipfs-cluster-ctl pin add --no-status not-a-cid >/dev/null 2>&1; then
  fail 'invalid CID was accepted'
fi

# A restart on the same volume reuses the stored identity and pinset.
docker stop -t 20 "$container" >/dev/null
[ "$(docker inspect -f '{{.State.ExitCode}}' "$container")" = 0 ] ||
  fail "SIGTERM shutdown exited $(docker inspect -f '{{.State.ExitCode}}' "$container")"
docker rm "$container" >/dev/null
container=
start_peer
[ "$peer_id" = "$first_id" ] || fail "peer id changed across restart: $first_id -> $peer_id"
docker logs "$container" 2>&1 | grep -F 'Found IPFS cluster configuration' >/dev/null ||
  fail 'restart did not reuse the stored configuration'
docker exec "$container" ipfs-cluster-ctl pin ls "$cid" | grep -F "$cid" >/dev/null ||
  fail 'pinset was not persisted across restart'

printf 'SMOKE PASS image=%s\n' "$image"
