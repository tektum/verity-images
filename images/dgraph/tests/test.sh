#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
suffix=$$-$(date +%s)
net=verity-dgraph-$suffix
zero=verity-dgraph-zero-$suffix
alpha=verity-dgraph-alpha-$suffix
zero_data=verity-dgraph-zero-data-$suffix
alpha_data=verity-dgraph-alpha-data-$suffix
work=$(mktemp -d)
cleanup() {
  docker rm -f "$alpha" "$zero" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  docker volume rm "$zero_data" "$alpha_data" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

user=$(docker image inspect --format '{{.Config.User}}' "$image")
[ "$user" = 65532 ] || fail "unexpected user: $user"
entrypoint=$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")
[ "$entrypoint" = '["/usr/bin/dgraph"]' ] || fail "unexpected entrypoint: $entrypoint"
workdir=$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")
[ "$workdir" = /dgraph ] || fail "unexpected working directory: $workdir"

docker run --rm "$image" version >"$work/version.log" 2>&1 || fail "dgraph version failed: $(cat "$work/version.log")"
grep -q '^Dgraph version' "$work/version.log" || fail "version banner missing: $(cat "$work/version.log")"

if docker run --rm "$image" verity-unknown-command >"$work/bad-command.log" 2>&1; then
  fail 'unknown subcommand unexpectedly succeeded'
fi
grep -q 'unknown command "verity-unknown-command"' "$work/bad-command.log" ||
  fail "unknown subcommand error missing: $(cat "$work/bad-command.log")"

docker network create "$net" >/dev/null

start_cluster() {
  docker run -d --name "$zero" --network "$net" --network-alias zero \
    -v "$zero_data:/dgraph" "$image" zero --my=zero:5080 >/dev/null
  docker run -d --name "$alpha" --network "$net" --network-alias alpha \
    -v "$alpha_data:/dgraph" -p 127.0.0.1::8080 "$image" \
    alpha --my=alpha:7080 --zero=zero:5080 --security whitelist=0.0.0.0/0 >/dev/null
  port=$(docker port "$alpha" 8080/tcp | sed -n 's/^127\.0\.0\.1:\([0-9][0-9]*\)$/\1/p' | head -n1)
  [ -n "$port" ] || fail 'alpha HTTP port was not published'
  base=http://127.0.0.1:$port
  ready=false
  for _ in $(seq 1 60); do
    if curl -fsS --connect-timeout 1 --max-time 5 "$base/health" 2>/dev/null | grep -q '"status":"healthy"'; then
      ready=true
      break
    fi
    sleep 1
  done
  [ "$ready" = true ] || {
    docker logs "$zero" >&2 || true
    docker logs "$alpha" >&2 || true
    fail 'dgraph alpha never became healthy'
  }
}

stop_cluster() {
  docker stop -t 30 "$alpha" "$zero" >/dev/null
  for container in "$alpha" "$zero"; do
    code=$(docker inspect --format '{{.State.ExitCode}}' "$container")
    [ "$code" = 0 ] || {
      docker logs "$container" >&2 || true
      fail "$container exited $code on SIGTERM"
    }
  done
  docker rm "$alpha" "$zero" >/dev/null
}

query() {
  curl -fsS --connect-timeout 5 --max-time 30 -H 'Content-Type: application/dql' -X POST "$base/query" \
    -d '{ q(func: eq(name, "verity-smoke")) { name verity.count } }'
}

start_cluster

alter=$(curl -fsS --connect-timeout 5 --max-time 30 -X POST "$base/alter" -d 'name: string @index(exact) .
verity.count: int .')
printf '%s\n' "$alter" | grep -q '"code":"Success"' || fail "schema alter failed: $alter"

mutation=$(curl -fsS --connect-timeout 5 --max-time 30 -H 'Content-Type: application/rdf' -X POST "$base/mutate?commitNow=true" \
  -d '{ set {
_:node <name> "verity-smoke" .
_:node <verity.count> "42" .
} }')
printf '%s\n' "$mutation" | grep -q '"code":"Success"' || fail "mutation failed: $mutation"
printf '%s\n' "$mutation" | grep -q '"uids":{"node":"0x' || fail "mutation assigned no uid: $mutation"

result=$(query)
printf '%s\n' "$result" | grep -q '"q":\[{"name":"verity-smoke","verity.count":42}\]' ||
  fail "query did not return the mutated node: $result"

malformed=$(curl -sS --connect-timeout 5 --max-time 30 -H 'Content-Type: application/dql' -X POST "$base/query" -d '{ q(func: eq(name, ')
printf '%s\n' "$malformed" | grep -q 'Unclosed Brackets' || fail "malformed query was not rejected: $malformed"

bad_mutation=$(curl -sS --connect-timeout 5 --max-time 30 -H 'Content-Type: application/rdf' -X POST "$base/mutate?commitNow=true" \
  -d '{ set { _:node <verity.count> "not-an-int" . } }')
printf '%s\n' "$bad_mutation" | grep -q '"errors"' || fail "type-violating mutation was accepted: $bad_mutation"

# Replace both containers on the same data volumes and read the data back.
stop_cluster
start_cluster
result=$(query)
printf '%s\n' "$result" | grep -q '"q":\[{"name":"verity-smoke","verity.count":42}\]' ||
  fail "data did not persist across restart: $result"

printf 'SMOKE PASS dgraph mutate/query/persist\n'
