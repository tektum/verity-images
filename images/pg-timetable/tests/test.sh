#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
postgres_index='docker.io/library/postgres:17-alpine@sha256:742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193'
suffix=$$
backend="verity-pgtt-postgres-$suffix"
worker="verity-pgtt-worker-$suffix"
network="verity-pgtt-network-$suffix"
tmp=$(mktemp -d)

cleanup() {
  docker rm -f "$worker" "$backend" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  if docker inspect "$worker" >/dev/null 2>&1; then
    docker logs "$worker" >&2 || true
  fi
  exit 1
}

psql_q() {
  docker exec "$backend" psql -X -v ON_ERROR_STOP=1 -U postgres -d timetable \
    -At -c "$1"
}

# OCI contract.
[ "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532 ] ||
  fail 'image does not run as UID 65532'
[ "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/pg_timetable"]' ] ||
  fail 'unexpected entrypoint'
docker image inspect "$image" --format '{{json .Config.Env}}' |
  grep -F '"PGTT_RESTPORT=8008"' >/dev/null ||
  fail 'PGTT_RESTPORT=8008 missing from image environment'

# Version reports the pinned upstream release and commit.
docker run --rm "$image" --version >"$tmp/version.txt" 2>&1 ||
  fail '--version exited non-zero'
grep -F "Version:      $expected_version" "$tmp/version.txt" >/dev/null ||
  fail "--version does not report $expected_version"
commit=$(sed -n 's/^[[:space:]]*expected-commit: \([0-9a-f]\{40\}\)$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
grep -F "Git Commit:   $commit" "$tmp/version.txt" >/dev/null ||
  fail "--version does not report commit $commit"

# Negative: a missing client name is a configuration error and the worker
# never starts. Upstream exits 0 after printing the error, so assert the
# message and the absence of any startup log rather than the status.
docker run --rm "$image" --connstr 'postgres://x@127.0.0.1/x' \
  >"$tmp/noclient.log" 2>&1 || true
grep -E '^Configuration error: +The required flag .-c, --clientname. was not specified' \
  "$tmp/noclient.log" >/dev/null ||
  fail 'missing --clientname did not report a configuration error'
if grep -F 'Starting new session' "$tmp/noclient.log" >/dev/null; then
  fail 'worker started without --clientname'
fi

# A classic Docker image store cannot bind the index digest to a second
# platform's image, so pull the helper by its own per-platform child digest.
# The index bytes are verified against the pinned digest before a child is
# chosen, which keeps the pin authoritative.
image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
postgres_raw=$(docker buildx imagetools inspect --raw "$postgres_index") ||
  fail 'cannot inspect helper image index'
[ "sha256:$(printf '%s' "$postgres_raw" | sha256sum | cut -d' ' -f1)" = "${postgres_index#*@}" ] ||
  fail 'helper image index digest mismatch'
postgres_digest=$(printf '%s' "$postgres_raw" |
  jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') ||
  fail 'cannot resolve helper image digest'
case $postgres_digest in
  sha256:*) ;;
  *) fail "no unique linux/$image_arch helper image in $postgres_index" ;;
esac
postgres=docker.io/library/postgres@$postgres_digest
docker pull --quiet --platform "linux/$image_arch" "$postgres" >/dev/null ||
  fail 'cannot pull helper image'

docker network create "$network" >/dev/null
docker run --name "$backend" -d --network "$network" --network-alias postgres \
  -e POSTGRES_PASSWORD=smoke \
  -e POSTGRES_DB=timetable \
  "$postgres" >/dev/null

attempts=0
until docker exec "$backend" pg_isready -U postgres -d timetable >/dev/null 2>&1 &&
  psql_q 'SELECT 1' >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || {
    docker logs "$backend" >&2
    fail 'postgres did not become ready'
  }
  sleep 1
done

psql_q 'CREATE TABLE public.smoke_ticks (id bigserial PRIMARY KEY, at timestamptz NOT NULL DEFAULT now())' \
  >/dev/null || fail 'cannot create target table'

# The worker runs read-only as the image user and creates its schema itself.
docker run --name "$worker" -d --network "$network" --read-only \
  -p 127.0.0.1::8008 \
  "$image" \
  --clientname=smoke \
  --connstr='postgres://postgres:smoke@postgres:5432/timetable?sslmode=disable' >/dev/null
port=$(docker port "$worker" 8008/tcp | awk -F: 'NR == 1 { print $NF }')
[ -n "$port" ] || fail 'REST port 8008 is not published'

attempts=0
until curl --fail --silent --connect-timeout 1 --max-time 5 \
  "http://127.0.0.1:$port/readiness" >/dev/null; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || fail 'worker never reported /readiness'
  [ "$(docker inspect -f '{{.State.Running}}' "$worker")" = true ] ||
    fail 'worker exited before readiness'
  sleep 1
done
curl --fail --silent --max-time 5 "http://127.0.0.1:$port/liveness" >/dev/null ||
  fail '/liveness did not return success'

[ "$(psql_q "SELECT count(*) FROM pg_namespace WHERE nspname = 'timetable'")" = 1 ] ||
  fail 'worker did not create the timetable schema'

# Schedule a SQL chain through the public API and wait for real executions.
chain_id=$(psql_q "SELECT timetable.add_job('smoke-insert', '@every 2 seconds', 'INSERT INTO public.smoke_ticks DEFAULT VALUES')") ||
  fail 'timetable.add_job failed'
case $chain_id in
  ''|*[!0-9]*) fail "unexpected chain id: $chain_id" ;;
esac

attempts=0
until [ "$(psql_q 'SELECT count(*) FROM public.smoke_ticks')" -ge 2 ]; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 90 ] || fail 'scheduled chain did not insert two rows'
  sleep 1
done

log=$(psql_q "SELECT count(*) FROM timetable.execution_log
  WHERE chain_id = $chain_id AND client_name = 'smoke' AND kind = 'SQL'
    AND returncode = 0 AND command = 'INSERT INTO public.smoke_ticks DEFAULT VALUES'")
[ "$log" -ge 1 ] || fail 'no successful execution_log entry for the chain'

# Negative: a failing chain is recorded with a non-zero return code.
bad_id=$(psql_q "SELECT timetable.add_job('smoke-fail', '@every 2 seconds', 'SELECT 1/0')") ||
  fail 'timetable.add_job for failing chain failed'
attempts=0
until [ "$(psql_q "SELECT count(*) FROM timetable.execution_log WHERE chain_id = $bad_id AND returncode <> 0")" -ge 1 ]; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || fail 'failing chain was not logged with a non-zero return code'
  sleep 1
done
[ "$(docker inspect -f '{{.State.Running}}' "$worker")" = true ] ||
  fail 'worker stopped after a failing chain'

# Graceful shutdown on SIGTERM.
docker stop --time 20 "$worker" >/dev/null
[ "$(docker inspect -f '{{.State.ExitCode}}' "$worker")" = 0 ] ||
  fail "worker exit code after SIGTERM is $(docker inspect -f '{{.State.ExitCode}}' "$worker")"

rows=$(psql_q 'SELECT count(*) FROM public.smoke_ticks')
printf 'SMOKE PASS image=%s chain=%s rows=%s execution_log=%s\n' \
  "$image" "$chain_id" "$rows" "$log"
