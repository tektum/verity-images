#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
recipe="$(dirname "$0")/../melange.yaml"
version=$(sed -n 's/^  version: "\([0-9.]*\)".*$/\1/p' "$recipe")
postgres_index='docker.io/library/postgres:17-alpine@sha256:742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193'
minio_index='ghcr.io/tektum/minio@sha256:0120fdcb5c245d82d62e4214ecb3bab1de114bdf0537e9ec45df1fce3090c898'
label="verity-test=wal-g-$$"
network=verity-wal-g-smoke-$$
source_db=verity-wal-g-source-$$
restored_db=verity-wal-g-restored-$$
s3=verity-wal-g-s3-$$
restore_volume=verity-wal-g-restore-$$
work=$(mktemp -d)
# Hex-encoded 32-byte libsodium key; the backup is encrypted end to end.
key=000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker volume rm -f "$restore_volume" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  # MinIO writes as 65532; remove its files from a container before the host cleanup.
  [ ! -d "$work/s3" ] || docker run --rm -v "$work:/w" --entrypoint /bin/sh "${postgres:-$postgres_index}" \
    -c 'rm -rf /w/s3' >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ -n "$version" ] || fail 'could not read the recipe version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/wal-g"]' || fail 'unexpected entrypoint'

# stdout only: docker prints a platform mismatch warning on stderr for emulated arm64 runs.
out=$(docker run --rm --label "$label" --network none "$image" --version) || fail 'version failed'
case $out in
  "wal-g version v$version	"*"	PostgreSQL") ;;
  *) fail "version does not report v$version: $out" ;;
esac

# Negative: an unknown flag is rejected.
if docker run --rm --label "$label" --network none "$image" --definitely-not-a-flag >"$work/bad.log" 2>&1; then
  fail 'unknown flag was accepted'
fi
grep -q 'unknown flag' "$work/bad.log" || fail "unexpected unknown-flag error: $(cat "$work/bad.log")"

# Negative: a storage command without any storage configured is refused.
if docker run --rm --label "$label" --network none "$image" backup-list >"$work/nostorage.log" 2>&1; then
  fail 'backup-list ran without storage'
fi
grep -qi 'storage\|PREFIX' "$work/nostorage.log" ||
  fail "unexpected missing-storage error: $(cat "$work/nostorage.log")"

# Helper images are chosen by the platform of the image under test. The index
# bytes are verified against the pinned digest before a child is chosen.
image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
resolve() {
  index=$1
  raw=$(docker buildx imagetools inspect --raw "$index") || fail "cannot inspect $index"
  [ "sha256:$(printf '%s' "$raw" | sha256sum | cut -d' ' -f1)" = "${index#*@}" ] ||
    fail "helper image index digest mismatch: $index"
  digest=$(printf '%s' "$raw" |
    jq -r --arg arch "$image_arch" '
      [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
      | if length == 1 then .[0] else empty end') || fail "cannot resolve $index"
  case $digest in
    sha256:*) ;;
    *) fail "no unique linux/$image_arch child in $index" ;;
  esac
  ref=${index%%@*}
  ref=${ref%:*}@$digest
  docker pull --quiet --platform "linux/$image_arch" "$ref" >/dev/null || fail "cannot pull $ref"
  printf '%s\n' "$ref"
}
postgres=$(resolve "$postgres_index")
minio=$(resolve "$minio_index")

docker network create --label "$label" "$network" >/dev/null

# S3-compatible object storage; the bucket is a top-level directory.
mkdir -p "$work/s3/walg"
chmod -R 0777 "$work/s3"
docker run -d --name "$s3" --label "$label" --network "$network" --network-alias s3 \
  -v "$work/s3:/data" -e MINIO_ROOT_USER=verity-access-key \
  -e MINIO_ROOT_PASSWORD=verity-secret-key "$minio" server /data >/dev/null

docker run -d --name "$source_db" --label "$label" --network "$network" --network-alias postgres \
  -e POSTGRES_PASSWORD=smoke "$postgres" >/dev/null

wait_pg() {
  attempts=0
  until docker exec "$1" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 90 ] || {
      docker logs "$1" >&2 || true
      fail "postgres $1 did not become ready"
    }
    sleep 1
  done
}
psql() {
  container=$1
  shift
  docker exec "$container" psql -v ON_ERROR_STOP=1 -U postgres -At -c "$1"
}
wait_pg "$source_db"

attempts=0
until docker logs "$s3" 2>&1 | grep -q 'API:'; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || {
    docker logs "$s3" >&2 || true
    fail 'object storage did not become ready'
  }
  sleep 1
done

psql "$source_db" "CREATE TABLE ledger (id integer PRIMARY KEY, note text NOT NULL)" >/dev/null
psql "$source_db" "INSERT INTO ledger SELECT g, 'entry ' || g FROM generate_series(1, 500) g" >/dev/null

# wal-g runs as the postgres user of the helper image and reads its data directory.
pg_uid=$(docker exec "$source_db" id -u postgres)
pg_gid=$(docker exec "$source_db" id -g postgres)
walg() {
  docker run --rm --label "$label" --network "$network" --read-only --cap-drop ALL \
    --security-opt no-new-privileges --user "$pg_uid:$pg_gid" "$@"
}
# A failed part download is retried with backoff for hours by default; a local
# S3 needs no retry, so a broken restore fails at once.
storage_env() {
  printf '%s\n' -e AWS_ACCESS_KEY_ID=verity-access-key -e AWS_SECRET_ACCESS_KEY=verity-secret-key \
    -e AWS_REGION=us-east-1 -e AWS_ENDPOINT=http://s3:9000 -e AWS_S3_FORCE_PATH_STYLE=true \
    -e WALG_S3_PREFIX=s3://walg/smoke -e WALG_LIBSODIUM_KEY_TRANSFORM=hex \
    -e WALG_DOWNLOAD_FILE_RETRIES=1 \
    -e PGHOST=postgres -e PGUSER=postgres -e PGPASSWORD=smoke -e PGDATABASE=postgres
}
# shellcheck disable=SC2046
walg_src() {
  walg $(storage_env) -e WALG_LIBSODIUM_KEY="$key" --volumes-from "$source_db" "$image" "$@"
}
# shellcheck disable=SC2046
walg_restore() {
  walg_key=$1
  shift
  walg $(storage_env) -e WALG_LIBSODIUM_KEY="$walg_key" -v "$restore_volume:/restore" "$image" "$@"
}

walg_src backup-push /var/lib/postgresql/data >"$work/push.log" 2>&1 ||
  fail "backup-push failed: $(cat "$work/push.log")"

# Close the WAL segment that holds the backup end and archive the segments
# the backup needs, except the one still being written.
psql "$source_db" 'SELECT pg_switch_wal()' >/dev/null
current=$(psql "$source_db" 'SELECT pg_walfile_name(pg_current_wal_lsn())')
segments=$(docker exec "$source_db" ls /var/lib/postgresql/data/pg_wal |
  grep -E '^[0-9A-F]{24}$' | sort | awk -v cur="$current" '$0 < cur')
[ -n "$segments" ] || fail 'no completed WAL segment to archive'
for segment in $segments; do
  walg_src wal-push "/var/lib/postgresql/data/pg_wal/$segment" >"$work/walpush.log" 2>&1 ||
    fail "wal-push $segment failed: $(cat "$work/walpush.log")"
done

walg_src backup-list --json >"$work/list.json" 2>"$work/list.err" ||
  fail "backup-list failed: $(cat "$work/list.err")"
[ "$(jq 'length' "$work/list.json")" = 1 ] || fail "unexpected backup list: $(cat "$work/list.json")"
backup=$(jq -r '.[0].backup_name' "$work/list.json")
case $backup in
  base_*) ;;
  *) fail "unexpected backup name: $backup" ;;
esac

docker volume create --label "$label" "$restore_volume" >/dev/null
docker run --rm --label "$label" -v "$restore_volume:/restore" --entrypoint /bin/sh "$postgres" \
  -c "mkdir -p /restore/data && chown $pg_uid:$pg_gid /restore/data && chmod 0700 /restore/data"

# Negative: the wrong key cannot decrypt the backup.
wrong=ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100
if walg_restore "$wrong" backup-fetch /restore/data LATEST >"$work/wrongkey.log" 2>&1; then
  fail 'backup-fetch succeeded with the wrong key'
fi
# libsodium authentication rejects every chunk sealed under the other key.
grep -q 'corrupted chunk' "$work/wrongkey.log" ||
  fail "unexpected wrong-key error: $(cat "$work/wrongkey.log")"
docker run --rm --label "$label" -v "$restore_volume:/restore" --entrypoint /bin/sh "$postgres" \
  -c "find /restore/data -mindepth 1 -delete"

walg_restore "$key" backup-fetch /restore/data LATEST >"$work/fetch.log" 2>&1 ||
  fail "backup-fetch failed: $(cat "$work/fetch.log")"
for segment in $segments; do
  walg_restore "$key" wal-fetch "$segment" "/restore/data/pg_wal/$segment" >"$work/walfetch.log" 2>&1 ||
    fail "wal-fetch $segment failed: $(cat "$work/walfetch.log")"
done

# The restored data directory starts as a working server with the backed-up rows.
# PGDATA points into the restore volume: the image's anonymous VOLUME at
# /var/lib/postgresql/data would shadow a volume mounted at its parent.
docker run -d --name "$restored_db" --label "$label" --network "$network" \
  -v "$restore_volume:/restore" -e PGDATA=/restore/data -e POSTGRES_PASSWORD=smoke "$postgres" >/dev/null
wait_pg "$restored_db"
docker logs "$restored_db" 2>&1 | grep -q 'Skipping initialization' ||
  fail "restored server initialized a new cluster: $(docker logs "$restored_db" 2>&1 | tail -n 20)"
[ "$(psql "$restored_db" 'SELECT count(*), sum(id) FROM ledger')" = '500|125250' ] ||
  fail 'restored table does not hold the backed-up rows'
[ "$(psql "$restored_db" 'SELECT note FROM ledger WHERE id = 42')" = 'entry 42' ] ||
  fail 'restored row content differs'

printf 'SMOKE PASS image=%s\n' "$image"
