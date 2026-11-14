#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
config="$here/../apko.yaml"
version=$(sed -n 's/^    - gdal-tools=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

# The container runs as 65532 and writes its outputs into the bind-mounted
# working directory; the root filesystem stays read-only.
chmod 0777 "$work"

run() {
  docker run --rm --network none --read-only --cap-drop=ALL \
    -v "$work:/work" "$image" "$@"
}

# expect_failure NAME PATTERN COMMAND...: COMMAND must exit non-zero and print PATTERN.
expect_failure() {
  name=$1
  pattern=$2
  shift 2
  rc=0
  run "$@" >"$work/$name.out" 2>&1 || rc=$?
  test "$rc" -ne 0 || fail "$name unexpectedly succeeded: $(cat "$work/$name.out")"
  grep -F -- "$pattern" "$work/$name.out" >/dev/null ||
    fail "$name diagnostic '$pattern' is missing: $(cat "$work/$name.out")"
}

[ -n "$version" ] || fail 'could not read the pinned gdal-tools version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = null ||
  fail 'unexpected entrypoint; the image is a toolbox and takes the tool as its command'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = \
  '["gdalinfo","--version"]' || fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

# The default command reports the pinned release, and so does the unified CLI.
# Match the release literally: "GDAL 3.13.3 "Name", released ...".
reports_version() {
  case $(sed -n 1p "$1") in
    "GDAL $version "* | "GDAL $version,"*) return 0 ;;
  esac
  return 1
}
docker run --rm --network none --read-only --cap-drop=ALL "$image" >"$work/default" 2>&1 ||
  fail "default command failed: $(cat "$work/default")"
reports_version "$work/default" ||
  fail "default command does not report GDAL $version: $(cat "$work/default")"
run gdal --version >"$work/cli-version" 2>&1 || fail 'gdal --version failed'
reports_version "$work/cli-version" ||
  fail "gdal --version does not report GDAL $version: $(cat "$work/cli-version")"

# Vector: GeoJSON -> GeoPackage round trip keeps every feature and attribute.
cat >"$work/cities.geojson" <<'EOF'
{"type":"FeatureCollection","crs":{"type":"name","properties":{"name":"urn:ogc:def:crs:OGC:1.3:CRS84"}},"features":[
{"type":"Feature","properties":{"name":"Berlin","population":3645000,"capital":true},"geometry":{"type":"Point","coordinates":[13.4,52.5]}},
{"type":"Feature","properties":{"name":"Hamburg","population":1841000,"capital":false},"geometry":{"type":"Point","coordinates":[10.0,53.55]}},
{"type":"Feature","properties":{"name":"Null Island","population":0,"capital":false},"geometry":{"type":"Point","coordinates":[0.0,0.0]}}]}
EOF
chmod 0644 "$work/cities.geojson"

run ogr2ogr -f GPKG cities.gpkg cities.geojson -nln cities >"$work/to-gpkg" 2>&1 ||
  fail "ogr2ogr GeoJSON -> GPKG failed: $(cat "$work/to-gpkg")"
run ogrinfo -ro -so cities.gpkg cities >"$work/summary" 2>&1 ||
  fail "ogrinfo summary failed: $(cat "$work/summary")"
grep -F "using driver \`GPKG' successful" "$work/summary" >/dev/null ||
  fail 'output was not opened as a GeoPackage'
grep -Fx 'Geometry: Point' "$work/summary" >/dev/null || fail 'geometry type is not Point'
grep -Fx 'Feature Count: 3' "$work/summary" >/dev/null || fail 'feature count is not 3'
grep -Fx 'Extent: (0.000000, 0.000000) - (13.400000, 53.550000)' "$work/summary" >/dev/null ||
  fail "unexpected layer extent: $(cat "$work/summary")"
grep -F 'ID["EPSG",4326]' "$work/summary" >/dev/null || fail 'layer SRS is not EPSG:4326'
grep -Fx 'population: Integer (0.0)' "$work/summary" >/dev/null || fail 'population field type lost'
grep -Fx 'capital: Integer(Boolean) (0.0)' "$work/summary" >/dev/null || fail 'boolean subtype lost'

run ogrinfo -ro cities.gpkg -sql "SELECT name, population, capital FROM cities WHERE name = 'Berlin'" \
  >"$work/berlin" 2>&1 || fail "ogrinfo SQL failed: $(cat "$work/berlin")"
grep -Fx 'Feature Count: 1' "$work/berlin" >/dev/null || fail 'SQL filter did not select one feature'
grep -Fx '  population (Integer) = 3645000' "$work/berlin" >/dev/null ||
  fail "Berlin population did not round-trip: $(cat "$work/berlin")"
grep -Fx '  capital (Integer(Boolean)) = 1' "$work/berlin" >/dev/null ||
  fail "Berlin capital flag did not round-trip: $(cat "$work/berlin")"

# Reprojection needs PROJ's proj.db: WGS 84 lon/lat -> Web Mercator.
run ogr2ogr -f GeoJSON -t_srs EPSG:3857 -lco COORDINATE_PRECISION=2 merc.geojson cities.gpkg cities \
  >"$work/reproject" 2>&1 || fail "ogr2ogr -t_srs EPSG:3857 failed: $(cat "$work/reproject")"
grep -F '"name": "urn:ogc:def:crs:EPSG::3857"' "$work/merc.geojson" >/dev/null ||
  fail 'reprojected output is not EPSG:3857'
grep -F '"name":"Berlin"' "$work/merc.geojson" |
  grep -F '"coordinates":[1491681.18,6891041.72]' >/dev/null ||
  fail "Berlin was not reprojected to Web Mercator: $(cat "$work/merc.geojson")"
grep -F '"name":"Hamburg"' "$work/merc.geojson" |
  grep -F '"coordinates":[1113194.91,7085388.17]' >/dev/null ||
  fail "Hamburg was not reprojected to Web Mercator: $(cat "$work/merc.geojson")"

# Raster: an ASCII grid with known cells, converted to GeoTIFF.
cat >"$work/grid.asc" <<'EOF'
ncols 4
nrows 3
xllcorner 0
yllcorner 0
cellsize 10
NODATA_value -9999
1 2 3 4
5 6 7 8
9 10 11 12
EOF
chmod 0644 "$work/grid.asc"

run gdal_translate -q -of GTiff -a_srs EPSG:4326 grid.asc grid.tif >"$work/translate" 2>&1 ||
  fail "gdal_translate AAIGrid -> GTiff failed: $(cat "$work/translate")"
run gdalinfo -checksum -stats grid.tif >"$work/grid-info" 2>&1 ||
  fail "gdalinfo on the GeoTIFF failed: $(cat "$work/grid-info")"
grep -Fx 'Driver: GTiff/GeoTIFF' "$work/grid-info" >/dev/null || fail 'raster is not a GeoTIFF'
grep -Fx 'Size is 4, 3' "$work/grid-info" >/dev/null || fail 'raster size is not 4x3'
grep -Fx 'Origin = (0.000000000000000,30.000000000000000)' "$work/grid-info" >/dev/null ||
  fail 'raster origin is wrong'
grep -F 'Type=Int32' "$work/grid-info" >/dev/null || fail 'raster band type is not Int32'
grep -Fx '  Checksum=71' "$work/grid-info" >/dev/null ||
  fail "raster checksum is not 71: $(cat "$work/grid-info")"
grep -Fx '    STATISTICS_MINIMUM=1' "$work/grid-info" >/dev/null || fail 'raster minimum is not 1'
grep -Fx '    STATISTICS_MAXIMUM=12' "$work/grid-info" >/dev/null || fail 'raster maximum is not 12'
test "$(run gdallocationinfo -valonly grid.tif 2 1)" = 7 || fail 'pixel (2,1) is not 7'

run gdal_create -q -of GTiff -outsize 5 4 -bands 1 -ot Byte -burn 7 \
  -a_srs EPSG:4326 -a_ullr 0 4 5 0 const.tif >"$work/create" 2>&1 ||
  fail "gdal_create failed: $(cat "$work/create")"
run gdalinfo -checksum const.tif >"$work/const-info" 2>&1 || fail 'gdalinfo on gdal_create output failed'
grep -Fx 'Size is 5, 4' "$work/const-info" >/dev/null || fail 'gdal_create size is not 5x4'
grep -Fx '  Checksum=126' "$work/const-info" >/dev/null ||
  fail "gdal_create checksum is not 126: $(cat "$work/const-info")"

# Raster reprojection: latitude 30 N maps to y = 3503549.844 in Web Mercator.
run gdalwarp -q -t_srs EPSG:3857 grid.tif warped.tif >"$work/warp" 2>&1 ||
  fail "gdalwarp failed: $(cat "$work/warp")"
run gdalinfo warped.tif >"$work/warped-info" 2>&1 || fail 'gdalinfo on the warped raster failed'
grep -F 'ID["EPSG",3857]' "$work/warped-info" >/dev/null || fail 'warped raster is not EPSG:3857'
grep -E '^Upper Left +\( +0\.000, 3503549\.844\)' "$work/warped-info" >/dev/null ||
  fail "warped raster origin is wrong: $(cat "$work/warped-info")"

# Negative cases: each failure is a non-zero exit with a usable diagnostic.
expect_failure missing-raster 'missing.tif: No such file or directory' gdalinfo missing.tif
expect_failure missing-vector 'missing.gpkg: No such file or directory' ogrinfo -ro missing.gpkg
expect_failure unknown-vector-driver "Unable to find driver \`NoSuchDriver'" \
  ogr2ogr -f NoSuchDriver out.x cities.geojson
expect_failure unknown-raster-driver "Output driver \`NoSuchDriver' not recognised" \
  gdal_translate -of NoSuchDriver grid.asc out.x
expect_failure unknown-crs 'crs not found: EPSG:999999' \
  ogr2ogr -f GeoJSON -t_srs EPSG:999999 bad-crs.geojson cities.geojson

printf 'SMOKE PASS image=%s\n' "$image"
