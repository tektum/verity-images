#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
config="$(dirname "$0")/../apko.yaml"
version=$(sed -n 's/^    - buf=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
work=$(mktemp -d)

trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ -n "$version" ] || fail 'could not read the pinned buf version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/buf"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /workspace ||
  fail 'unexpected working directory'

# Every run is offline: lint, build, format and breaking checks need no registry.
run() {
  dir=$1
  shift
  docker run --rm --network none -v "$dir:/workspace:ro" "$image" "$@"
}

docker run --rm --network none "$image" --version >"$work/version" 2>&1 ||
  fail 'version failed'
grep -Fx "$version" "$work/version" >/dev/null ||
  fail "version does not report $version: $(cat "$work/version")"

rc=0
docker run --rm --network none "$image" --definitely-invalid >"$work/flag" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'unknown flag: --definitely-invalid' "$work/flag" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/flag")"

mkdir -p "$work/good/acme/weather/v1" "$work/bad/acme/weather/v1" \
  "$work/breaking/acme/weather/v1"
for dir in good bad breaking; do
  cat >"$work/$dir/buf.yaml" <<'YAML'
version: v2
lint:
  use:
    - STANDARD
breaking:
  use:
    - FILE
YAML
done

cat >"$work/good/acme/weather/v1/weather.proto" <<'PROTO'
syntax = "proto3";

package acme.weather.v1;

// Forecast is a daily forecast for one city.
message Forecast {
  // City name.
  string city = 1;
  // Expected high in degrees Celsius.
  int32 high_celsius = 2;
}

// GetForecastRequest asks for one city.
message GetForecastRequest {
  // City name.
  string city = 1;
}

// GetForecastResponse returns the forecast.
message GetForecastResponse {
  // The forecast.
  Forecast forecast = 1;
}

// WeatherService serves forecasts.
service WeatherService {
  // GetForecast returns the forecast for one city.
  rpc GetForecast(GetForecastRequest) returns (GetForecastResponse);
}
PROTO

# Lint failure: a lower-case message name violates MESSAGE_PASCAL_CASE.
sed 's/^message Forecast {/message forecast_data {/; s/^  Forecast forecast = 1;/  forecast_data forecast = 1;/' \
  "$work/good/acme/weather/v1/weather.proto" >"$work/bad/acme/weather/v1/weather.proto"

# Breaking change: field 2 is removed from Forecast.
grep -v 'high_celsius\|Expected high' "$work/good/acme/weather/v1/weather.proto" \
  >"$work/breaking/acme/weather/v1/weather.proto"
chmod -R a+rX "$work"

run "$work/good" lint >"$work/lint-good" 2>&1 ||
  fail "lint of the valid module failed: $(cat "$work/lint-good")"
test ! -s "$work/lint-good" || fail "lint of the valid module reported: $(cat "$work/lint-good")"

rc=0
run "$work/bad" lint >"$work/lint-bad" 2>&1 || rc=$?
test "$rc" -eq 100 || fail "lint of the invalid module exited $rc: $(cat "$work/lint-bad")"
grep -F 'acme/weather/v1/weather.proto:6:9:Message name "forecast_data" should be PascalCase, such as "ForecastData".' \
  "$work/lint-bad" >/dev/null || fail "lint diagnostic is missing: $(cat "$work/lint-bad")"

run "$work/good" build -o -#format=json >"$work/image.json" 2>"$work/build.err" ||
  fail "build failed: $(cat "$work/build.err")"
grep -F '"name":"acme/weather/v1/weather.proto"' "$work/image.json" >/dev/null ||
  fail 'build image is missing the source file'
grep -F '"name":"GetForecast"' "$work/image.json" >/dev/null ||
  fail 'build image is missing the service method'

run "$work/good" format --exit-code >"$work/format" 2>&1 ||
  fail "format check of the valid module failed: $(cat "$work/format")"

rc=0
docker run --rm --network none -v "$work/breaking:/workspace:ro" -v "$work/good:/against:ro" \
  "$image" breaking --against /against >"$work/breaking.out" 2>&1 || rc=$?
test "$rc" -eq 100 || fail "breaking check exited $rc: $(cat "$work/breaking.out")"
grep -F 'Previously present field "2" with name "high_celsius" on message "Forecast" was deleted.' \
  "$work/breaking.out" >/dev/null || fail "breaking diagnostic is missing: $(cat "$work/breaking.out")"

printf 'SMOKE PASS\n'
