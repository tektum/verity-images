#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
flavor=${2:-plain}
postgres_index='docker.io/library/postgres:17-alpine@sha256:742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193'
backend="verity-postgres-exporter-postgres-$$"
exporter="verity-postgres-exporter-exporter-$$"
orphan="verity-postgres-exporter-orphan-$$"
network="verity-postgres-exporter-network-$$"
tmp=$(mktemp -d)

cleanup() {
  docker rm -f "$exporter" "$orphan" "$backend" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

wait_metrics() {
  # $1 container, $2 host port, $3 output file, $4 required line (fixed, whole line)
  attempts=0
  until curl --fail --silent --connect-timeout 1 --max-time 5 \
    "http://127.0.0.1:$2/metrics" >"$3" 2>/dev/null && grep -Fx "$4" "$3" >/dev/null; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 30 ] || {
      docker logs "$1" >&2
      fail "metrics did not contain: $4"
    }
    sleep 1
  done
}

test "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532 ||
  fail 'image must run as UID 65532'
test "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/postgres_exporter"]' ||
  fail 'unexpected entrypoint'
docker run --rm "$image" --version 2>&1 | grep -E 'postgres_exporter, version 0\.' >/dev/null ||
  fail 'unexpected exporter version'

created=$(docker create "$image")
docker cp "$created:/usr/bin/postgres_exporter" "$tmp/postgres_exporter"
docker rm "$created" >/dev/null
if [ "$flavor" = fips ]; then
  go version -m "$tmp/postgres_exporter" | grep -q 'GOFIPS140=v1.0.0' ||
    fail 'fips flavor must be built with GOFIPS140=v1.0.0'
elif go version -m "$tmp/postgres_exporter" | grep -q 'GOFIPS140='; then
  fail 'plain flavor must not set GOFIPS140'
fi

image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
# Pull a pinned helper index by its per-platform child digest. A classic Docker
# image store cannot bind an index digest to a second platform's image, so the
# index bytes are verified against the pin before a child is chosen, which keeps
# the pin authoritative.
resolve_helper() {
  helper_index=$1
  helper_raw=$(docker buildx imagetools inspect --raw "$helper_index") ||
    fail 'cannot inspect helper image index'
  [ "sha256:$(printf '%s' "$helper_raw" | sha256sum | cut -d' ' -f1)" = "${helper_index#*@}" ] ||
    fail 'helper image index digest mismatch'
  helper_digest=$(printf '%s' "$helper_raw" |
    jq -r --arg arch "$image_arch" '
      [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
      | if length == 1 then .[0] else empty end') ||
    fail 'cannot resolve helper image digest'
  case $helper_digest in
    sha256:*) ;;
    *) fail "no unique linux/$image_arch helper image in $helper_index" ;;
  esac
  helper=${helper_index%%:*}@$helper_digest
  docker pull --quiet --platform "linux/$image_arch" "$helper" >/dev/null ||
    fail 'cannot pull helper image'
}
resolve_helper "$postgres_index"
postgres=$helper

docker network create "$network" >/dev/null
docker run --name "$backend" -d --network "$network" --network-alias postgres \
  -e POSTGRES_USER=exporter -e POSTGRES_PASSWORD=exporter-secret "$postgres" >/dev/null
attempts=0
until docker exec "$backend" pg_isready -h 127.0.0.1 -U exporter >/dev/null 2>&1 &&
  docker exec "$backend" psql -h 127.0.0.1 -U exporter -tAc 'select 1' >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || { docker logs "$backend" >&2; fail 'postgres fixture did not become ready'; }
  sleep 1
done

# The FIPS flavor must also work with the Go FIPS module enforced.
godebug=
[ "$flavor" != fips ] || godebug=fips140=only

docker run --name "$exporter" -d --network "$network" --read-only \
  -e GODEBUG="$godebug" \
  -e DATA_SOURCE_NAME='postgresql://exporter:exporter-secret@postgres:5432/postgres?sslmode=disable' \
  -p 127.0.0.1::9187 "$image" >/dev/null
port=$(docker port "$exporter" 9187/tcp | awk -F: 'NR == 1 { print $2 }')
test -n "$port"

wait_metrics "$exporter" "$port" "$tmp/metrics" 'pg_up 1'
grep -F 'pg_static{' "$tmp/metrics" >/dev/null || fail 'pg_static missing'
grep -F 'pg_stat_database_numbackends{' "$tmp/metrics" >/dev/null ||
  fail 'pg_stat_database_numbackends missing'

# Rejected credentials must surface as pg_up 0 while the exporter keeps serving.
docker run --name "$orphan" -d --network "$network" \
  -e GODEBUG="$godebug" \
  -e DATA_SOURCE_NAME='postgresql://exporter:wrong-password@postgres:5432/postgres?sslmode=disable' \
  -p 127.0.0.1::9187 "$image" >/dev/null
orphan_port=$(docker port "$orphan" 9187/tcp | awk -F: 'NR == 1 { print $2 }')
wait_metrics "$orphan" "$orphan_port" "$tmp/orphan.metrics" 'pg_up 0'

if docker run --rm "$image" --no-such-flag >"$tmp/invalid.log" 2>&1; then
  fail 'unknown flag unexpectedly succeeded'
fi
grep -F 'no-such-flag' "$tmp/invalid.log" >/dev/null ||
  fail 'unknown flag error missing'

docker stop "$exporter" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$exporter")" = 0 ] ||
  fail 'exporter did not stop cleanly on SIGTERM'

printf 'SMOKE PASS image=%s flavor=%s\n' "$image" "$flavor"
