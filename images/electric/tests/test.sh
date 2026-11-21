#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^    - electric=\([0-9][0-9.]*\)-r[0-9]*$/\1/p' \
  "$(dirname "$0")/../apko.yaml")
[ -n "$expected_version" ] || { printf '%s\n' 'electric package pin not found' >&2; exit 1; }
postgres_index='docker.io/library/postgres:17-alpine@sha256:742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193'
backend="verity-electric-postgres-$$"
sync="verity-electric-sync-$$"
network="verity-electric-network-$$"
work=$(mktemp -d)

cleanup() {
  docker rm -f "$sync" "$backend" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# Upstream contract: ENTRYPOINT ["/app/bin/entrypoint"], CMD ["start"], WORKDIR /app.
user=$(docker image inspect -f '{{.Config.User}}' "$image")
[ "$user" = 65532 ] || fail "image user is $user, want 65532"
entrypoint=$(docker image inspect -f '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' "$image")
[ "$entrypoint" = '["/app/bin/entrypoint"] ["start"]' ] || fail "unexpected entrypoint: $entrypoint"
workdir=$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")
[ "$workdir" = /app ] || fail "unexpected working directory: $workdir"

version=$(timeout 60 docker run --rm --network none "$image" version 2>&1) ||
  fail "electric version failed: $version"
[ "$version" = "electric $expected_version" ] ||
  fail "unexpected version '$version', want electric $expected_version"

image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
# Pull the pinned Postgres index by its per-platform child digest. A classic
# Docker image store cannot bind an index digest to a second platform's image,
# so the index bytes are verified against the pin before a child is chosen.
postgres_raw=$(docker buildx imagetools inspect --raw "$postgres_index") ||
  fail 'cannot inspect the Postgres fixture index'
[ "sha256:$(printf '%s' "$postgres_raw" | sha256sum | cut -d' ' -f1)" = "${postgres_index#*@}" ] ||
  fail 'Postgres fixture index digest mismatch'
postgres_digest=$(printf '%s' "$postgres_raw" |
  jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') ||
  fail 'cannot resolve the Postgres fixture digest'
case $postgres_digest in
  sha256:*) ;;
  *) fail "no unique linux/$image_arch Postgres fixture in $postgres_index" ;;
esac
postgres=${postgres_index%%:*}@$postgres_digest
docker pull --quiet --platform "linux/$image_arch" "$postgres" >/dev/null || fail 'cannot pull the Postgres fixture'

docker network create "$network" >/dev/null
docker run --name "$backend" -d --network "$network" --network-alias postgres \
  -e POSTGRES_PASSWORD=smoke-secret -e POSTGRES_DB=smoke "$postgres" \
  postgres -c wal_level=logical >/dev/null
attempts=0
until docker exec "$backend" pg_isready -h 127.0.0.1 -U postgres -d smoke >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 90 ] || { docker logs "$backend" >&2; fail 'Postgres fixture did not become ready'; }
  sleep 1
done
docker exec "$backend" psql -v ON_ERROR_STOP=1 -U postgres -d smoke -c "
  CREATE TABLE fruit (id INT PRIMARY KEY, name TEXT NOT NULL);
  INSERT INTO fruit VALUES (1, 'apple'), (2, 'banana');" >/dev/null ||
  fail 'cannot seed the Postgres fixture'

docker run --name "$sync" -d --network "$network" -p 127.0.0.1::3000 \
  -e DATABASE_URL='postgresql://postgres:smoke-secret@postgres:5432/smoke?sslmode=disable' \
  -e ELECTRIC_INSECURE=true "$image" >/dev/null
port=$(docker port "$sync" 3000/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || fail 'electric port 3000 is not published'
base="http://127.0.0.1:$port"

attempts=0
until curl --fail --silent --connect-timeout 1 --max-time 5 "$base/v1/health" >"$work/health.json" 2>/dev/null &&
  jq -e '.status == "active"' "$work/health.json" >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 120 ] || { cat "$work/health.json" >&2; docker logs "$sync" >&2; fail 'electric did not report active health'; }
  sleep 1
done

# Initial shape snapshot: offset=-1 returns every row as an insert.
curl --fail --silent --show-error --max-time 30 -D "$work/shape.headers" \
  "$base/v1/shape?table=fruit&offset=-1" >"$work/shape.json" ||
  { docker logs "$sync" >&2; fail 'shape request failed'; }
rows=$(jq -c '[.[] | select(.headers.operation == "insert") | .value] | sort_by(.id)' "$work/shape.json") ||
  { cat "$work/shape.json" >&2; fail 'shape response is not a JSON message array'; }
[ "$rows" = '[{"id":"1","name":"apple"},{"id":"2","name":"banana"}]' ] ||
  { cat "$work/shape.json" >&2; fail "unexpected shape rows: $rows"; }
handle=$(tr -d '\r' <"$work/shape.headers" | awk -F': ' 'tolower($1) == "electric-handle" { print $2 }')
offset=$(tr -d '\r' <"$work/shape.headers" | awk -F': ' 'tolower($1) == "electric-offset" { print $2 }')
[ -n "$handle" ] && [ -n "$offset" ] ||
  { cat "$work/shape.headers" >&2; fail 'shape response lacks electric-handle or electric-offset'; }

# Replication: a row inserted after the snapshot reaches the shape log.
docker exec "$backend" psql -v ON_ERROR_STOP=1 -U postgres -d smoke \
  -c "INSERT INTO fruit VALUES (3, 'cherry')" >/dev/null || fail 'cannot insert the live row'
curl --fail --silent --show-error --max-time 60 \
  "$base/v1/shape?table=fruit&handle=$handle&offset=$offset&live=true" >"$work/live.json" ||
  { docker logs "$sync" >&2; fail 'live shape request failed'; }
live=$(jq -c '[.[] | select(.headers.operation == "insert") | .value]' "$work/live.json")
[ "$live" = '[{"id":"3","name":"cherry"}]' ] ||
  { cat "$work/live.json" >&2; fail "live shape did not stream the inserted row: $live"; }

# Shape state persists under the default ELECTRIC_STORAGE_DIR as UID 65532.
docker exec "$sync" sh -c 'test -d /app/persistent/shapes && test -w /app/persistent' ||
  fail 'shape storage was not written under /app/persistent'

# Negative case: an unknown table is rejected with 400.
status=$(curl --silent --output "$work/missing.json" --write-out '%{http_code}' --max-time 30 \
  "$base/v1/shape?table=no_such_table&offset=-1")
[ "$status" = 400 ] || { cat "$work/missing.json" >&2; fail "unknown table returned HTTP $status, want 400"; }

printf '%s\n' "electric $expected_version smoke test passed"
