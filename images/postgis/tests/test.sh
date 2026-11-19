#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
container=verity-postgis-smoke-$$
volume=$container-data
tmp=$(mktemp -d)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fail() {
  docker logs "$container" >&2 2>/dev/null || true
  printf '%s\n' "$1" >&2
  exit 1
}

# The PostGIS release comes from the reviewed lock, so a lock refresh needs no
# test edit.
postgis_version=$(jq -r '[.contents.packages[] | select(.name == "postgis-18") | .version]
  | unique | if length == 1 then .[0] | sub("-r[0-9]+$"; "") else empty end' \
  "$here/../apko.lock.json")
[ -n "$postgis_version" ] || fail 'could not read the locked postgis-18 version'

printf '%s\n' smoke-password >"$tmp/password"
cat >"$tmp/init.sql" <<'EOF'
CREATE EXTENSION postgis;
CREATE TABLE smoke_places (name text PRIMARY KEY, geom geometry(Point, 4326) NOT NULL);
CREATE INDEX smoke_places_geom ON smoke_places USING gist (geom);
INSERT INTO smoke_places VALUES
  ('origin', ST_SetSRID(ST_MakePoint(0, 0), 4326)),
  ('north', ST_SetSRID(ST_MakePoint(0, 1), 4326)),
  ('far', ST_SetSRID(ST_MakePoint(120, 45), 4326));
EOF
docker volume create "$volume" >/dev/null

test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["docker-entrypoint.sh"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["postgres"]' ||
  fail 'unexpected command'
test "$(docker image inspect --format '{{.Config.StopSignal}}' "$image")" = SIGINT ||
  fail 'unexpected stop signal'
test -z "$(docker image inspect --format '{{.Config.User}}' "$image")" ||
  fail 'entrypoint must start as root and drop to postgres'
docker image inspect --format '{{range $path, $_ := .Config.Volumes}}{{println $path}}{{end}}' \
  "$image" | grep -qx /var/lib/postgresql || fail 'data volume is not declared'

# Without a superuser password the entrypoint must refuse to initialize.
if docker run --rm "$image" >"$tmp/negative.log" 2>&1; then
  cat "$tmp/negative.log" >&2
  fail 'image started without POSTGRES_PASSWORD'
fi
grep -q 'Database is uninitialized and superuser password is not specified' "$tmp/negative.log" ||
  fail 'missing password diagnostic is absent'

start() {
  docker run -d --name "$container" \
    -e POSTGRES_PASSWORD_FILE=/run/secrets/password \
    -v "$volume":/var/lib/postgresql \
    -v "$tmp/password":/run/secrets/password:ro \
    -v "$tmp/init.sql":/docker-entrypoint-initdb.d/10-postgis.sql:ro \
    "$image" >/dev/null
}

ready() {
  attempts=0
  while ! docker exec "$container" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 90 ] || fail 'postgres did not become ready'
    sleep 1
  done
}

sql() {
  docker exec "$container" sh -c \
    'PGPASSWORD=smoke-password psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U postgres -d postgres -Atqc "$1"' \
    sh "$1"
}

expect() {
  actual=$(sql "$1") || fail "query failed: $1"
  [ "$actual" = "$2" ] || fail "query '$1' returned '$actual', expected '$2'"
}

start
ready
docker top "$container" -eo pid,uid,comm |
  awk '$3 == "postgres" { found = 1; if ($2 != 999) exit 1 } END { exit !found }' ||
  fail 'postgres does not run as UID 999'
sql 'SHOW server_version_num' | grep -q '^18' || fail 'server is not PostgreSQL 18'

# The init script created the extension, so the library loaded at bootstrap.
expect "SELECT extversion FROM pg_extension WHERE extname = 'postgis'" "$postgis_version"
expect 'SELECT postgis_lib_version()' "$postgis_version"
sql 'SELECT postgis_full_version()' >"$tmp/full-version" || fail 'postgis_full_version failed'
for component in "POSTGIS=\"$postgis_version" 'GEOS="' 'PROJ="' 'LIBXML="' 'LIBJSON="'; do
  grep -F "$component" "$tmp/full-version" >/dev/null ||
    fail "postgis_full_version lacks $component: $(cat "$tmp/full-version")"
done

# Spatial queries: geodesic distance, the GiST index and PROJ reprojection.
expect "SELECT round(ST_Distance(a.geom::geography, b.geom::geography)) FROM smoke_places a, smoke_places b WHERE a.name = 'origin' AND b.name = 'north'" 110574
expect "SELECT string_agg(name, ',' ORDER BY name) FROM smoke_places WHERE ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(0, 0.5), 4326)::geography, 60000)" 'north,origin'
sql "SET enable_seqscan = off; EXPLAIN SELECT name FROM smoke_places WHERE geom && ST_MakeEnvelope(-1, -1, 1, 2, 4326)" |
  grep -F 'smoke_places_geom' >/dev/null || fail 'GiST index is not used'
expect "SELECT ST_AsText(ST_SnapToGrid(ST_Transform(ST_SetSRID(ST_MakePoint(1, 1), 4326), 3857), 1))" \
  'POINT(111319 111325)'
expect "SELECT ST_AsGeoJSON(ST_Buffer(ST_MakePoint(0, 0), 1, 'quad_segs=1'))" \
  '{"type":"Polygon","coordinates":[[[1,0],[0,-1],[-1,0],[0,1],[1,0]]]}'
expect "SELECT ST_Area(ST_Intersection(ST_MakeEnvelope(0, 0, 2, 2), ST_MakeEnvelope(1, 1, 3, 3)))" 1

# Raster support links GDAL.
sql 'CREATE EXTENSION postgis_raster' >/dev/null || fail 'postgis_raster is not installable'
expect "SELECT ST_Value(ST_AddBand(ST_MakeEmptyRaster(2, 2, 0, 0, 1, -1, 0, 0, 4326), '8BUI'::text, 7, 0), 1, 1)" 7
sql 'SELECT postgis_gdal_version()' | grep -E '^GDAL [0-9]' >/dev/null || fail 'GDAL is not linked'
sql 'CREATE EXTENSION postgis_topology' >/dev/null || fail 'postgis_topology is not installable'

# Negative: invalid geometry input and an unknown SRID are rejected.
if sql "SELECT ST_GeomFromText('POINT(not a number)')" >"$tmp/bad-wkt" 2>&1; then
  fail 'invalid WKT was accepted'
fi
grep -F 'parse error' "$tmp/bad-wkt" >/dev/null || fail 'invalid WKT diagnostic is missing'
if sql 'SELECT ST_Transform(ST_SetSRID(ST_MakePoint(0, 0), 4326), 999999)' >"$tmp/bad-srid" 2>&1; then
  fail 'unknown SRID was accepted'
fi

# Persistence: the extension and spatial data survive a restart.
docker stop "$container" >/dev/null
docker rm "$container" >/dev/null
start
ready
expect "SELECT count(*) FROM smoke_places WHERE ST_Within(geom, ST_MakeEnvelope(-1, -1, 1, 2, 4326))" 2
expect 'SELECT postgis_lib_version()' "$postgis_version"

echo "postgis $postgis_version on PostgreSQL 18 smoke test passed"
