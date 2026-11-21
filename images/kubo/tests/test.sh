#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
volume="verity-kubo-test-$$"
daemon="verity-kubo-daemon-$$"
default="verity-kubo-default-$$"
api=/ip4/127.0.0.1/tcp/5001
# Known contents with fixed CIDv1 raw-leaves identifiers (sha2-256 of the bytes).
cli_content='verity kubo cli smoke test'
cli_cid=bafkreielhqf74x6t435yn6gkrvqtzz66zzhduwxyde6eouvrrcak4chcgm
rpc_content='verity kubo rpc smoke test'
rpc_cid=bafkreic5npkblyblj56uxlw5ywptlxd3r3bdcunclqel32xqtd4s7kpwei
# Well-formed CIDv1 of content that is never added to the repo.
unknown_cid=bafkreih7bichjeholvci6kklhbpdyjd4qjratevsvouabog27l4xfjoppu

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$daemon" "$default" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# Every container runs without network access.
ipfs_run() {
  docker run --rm -i --network none -v "$volume:/data/ipfs" "$image" "$@"
}

wait_api() {
  i=0
  until docker exec "$1" ipfs --api="$api" id >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -lt 60 ] || { docker logs "$1" >&2 || true; fail "$1: RPC API did not become ready"; }
    sleep 1
  done
}

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 1000 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/ipfs"]' ] \
  || fail 'unexpected entrypoint'
[ "$(docker image inspect -f '{{json .Config.Cmd}}' "$image")" = '["daemon","--init","--migrate=true"]' ] \
  || fail 'unexpected image command'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /data/ipfs ] \
  || fail 'unexpected working directory'
docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$image" \
  | grep -Fx 'IPFS_PATH=/data/ipfs' >/dev/null || fail 'IPFS_PATH is not /data/ipfs'

version_output=$(docker run --rm --network none "$image" version 2>&1) || fail 'ipfs version failed'
[ "$version_output" = "ipfs version $expected_version" ] || fail "unexpected version output: $version_output"

# Repo init in the writable data dir as the non-root user.
init_output=$(ipfs_run init 2>&1) || fail "ipfs init failed: $init_output"
printf '%s\n' "$init_output" | grep -F 'initializing IPFS node' >/dev/null \
  || fail "unexpected init output: $init_output"
peer_id=$(docker run --rm --network none -v "$volume:/data/ipfs" --entrypoint /usr/bin/ipfs "$image" \
  config Identity.PeerID 2>&1) || fail "repo is not readable by the image user: $peer_id"

# Offline CLI add and cat with a deterministic CID.
cid=$(printf '%s' "$cli_content" | ipfs_run add -Q --cid-version=1 --raw-leaves --stdin-name=cli.txt) \
  || fail 'ipfs add failed'
[ "$cid" = "$cli_cid" ] || fail "nondeterministic CID: got $cid, want $cli_cid"
out=$(ipfs_run cat "$cid") || fail 'ipfs cat failed'
[ "$out" = "$cli_content" ] || fail "ipfs cat returned unexpected content: $out"

# Negative: cat of an unknown CID with --offline must fail non-zero.
if out=$(ipfs_run --offline cat "$unknown_cid" 2>&1); then
  fail "offline cat of an unknown CID unexpectedly succeeded: $out"
fi
printf '%s\n' "$out" | grep -iF 'not found' >/dev/null || fail "unexpected unknown CID error: $out"

# Offline daemon on the same repo: add and cat through the RPC API on :5001.
docker run -d --name "$daemon" --network none -v "$volume:/data/ipfs" "$image" daemon --offline >/dev/null
wait_api "$daemon"
[ "$(docker top "$daemon" -o pid,uid | awk 'NR == 2 { print $2 }')" = 1000 ] \
  || fail 'daemon is not running as uid 1000'
daemon_log=$(docker logs "$daemon" 2>&1)
printf '%s\n' "$daemon_log" | grep -F 'RPC API server listening on /ip4/127.0.0.1/tcp/5001' >/dev/null \
  || fail "RPC API is not on :5001: $daemon_log"
printf '%s\n' "$daemon_log" | grep -F 'Gateway server listening on /ip4/127.0.0.1/tcp/8080' >/dev/null \
  || fail "gateway is not on :8080: $daemon_log"
cid=$(printf '%s' "$rpc_content" | docker exec -i "$daemon" \
  ipfs --api="$api" add -Q --cid-version=1 --raw-leaves --stdin-name=rpc.txt) || fail 'RPC add failed'
[ "$cid" = "$rpc_cid" ] || fail "nondeterministic RPC CID: got $cid, want $rpc_cid"
out=$(docker exec "$daemon" ipfs --api="$api" cat "$rpc_cid") || fail 'RPC cat failed'
[ "$out" = "$rpc_content" ] || fail "RPC cat returned unexpected content: $out"
out=$(docker exec "$daemon" ipfs --api="$api" cat "$cli_cid") || fail 'RPC cat of CLI content failed'
[ "$out" = "$cli_content" ] || fail "RPC cat of CLI content returned: $out"
if out=$(docker exec "$daemon" ipfs --api="$api" cat "$unknown_cid" 2>&1); then
  fail "RPC cat of an unknown CID on an offline daemon unexpectedly succeeded: $out"
fi
docker stop --time 20 "$daemon" >/dev/null
[ "$(docker inspect -f '{{.State.ExitCode}}' "$daemon")" = 0 ] \
  || { docker logs "$daemon" >&2 || true; fail 'offline daemon did not stop cleanly on SIGTERM'; }

# Default command: first start initializes an empty data dir and serves swarm on 4001.
docker run -d --name "$default" --network none "$image" >/dev/null
wait_api "$default"
default_log=$(docker logs "$default" 2>&1)
for want in 'initializing IPFS node' 'Swarm listening on 127.0.0.1:4001 (TCP+UDP)' \
  'RPC API server listening on /ip4/127.0.0.1/tcp/5001' 'Gateway server listening on /ip4/127.0.0.1/tcp/8080'; do
  printf '%s\n' "$default_log" | grep -F "$want" >/dev/null || fail "default command log lacks '$want': $default_log"
done
docker stop --time 20 "$default" >/dev/null
[ "$(docker inspect -f '{{.State.ExitCode}}' "$default")" = 0 ] \
  || { docker logs "$default" >&2 || true; fail 'default daemon did not stop cleanly on SIGTERM'; }

printf 'SMOKE PASS image=%s\n' "$image"
