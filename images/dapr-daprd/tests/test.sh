#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
name=dapr-daprd
container="verity-$name-test-$$"
cli=/daprd
work=$(mktemp -d)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  docker logs "$container" >&2 2>/dev/null || true
  exit 1
}

expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || fail 'package version not found in melange.yaml'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'OCI user is not 65532'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  "[\"$cli\"]" || fail 'unexpected entrypoint'
case $(docker image inspect --format '{{json .Config.Cmd}}' "$image") in
  null | '[]') ;;
  *) fail 'unexpected default command' ;;
esac
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = / ||
  fail 'unexpected working directory'

# The charts invoke the binary from the root, and the package keeps it in /usr/bin.
docker run --rm --network none --entrypoint /usr/bin/daprd "$image" --help >"$work/help" 2>&1 || true
grep -F -e '--app-id' "$work/help" >/dev/null ||
  { head -n 5 "$work/help" >&2; fail 'daprd help is missing the app id flag'; }

if docker run --rm --network none --read-only "$image" --definitely-invalid \
  >"$work/invalid" 2>&1; then
  fail 'unknown flag unexpectedly succeeded'
fi
grep -F -e 'unknown flag: --definitely-invalid' \
  -e 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'unknown flag diagnostic is missing'

wait_http() {
  url=$1
  want=$2
  i=0
  until code=$(curl --silent --output "$work/body" --write-out '%{http_code}' \
    --connect-timeout 1 --max-time 5 "$url") && [ "$code" = "$want" ]; do
    i=$((i + 1))
    [ "$i" -lt 30 ] || fail "$url did not return $want (last: ${code:-none})"
    sleep 1
  done
}

host_port() {
  port=$(docker port "$container" "$1/tcp" | awk -F: 'NR == 1 { print $NF }')
  [ -n "$port" ] || fail "port $1 is not published"
  printf '%s' "$port"
}

stop_clean() {
  docker stop "$container" >/dev/null
  test "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ||
    fail 'did not exit 0 on SIGTERM'
  docker logs "$container" 2>&1 | grep -F "version $expected_version" >/dev/null ||
    fail "startup log does not report version $expected_version"
  docker rm -f "$container" >/dev/null
}

version=$(docker run --rm --network none --read-only "$image" --version 2>&1) ||
  fail 'daprd --version failed'
[ "$version" = "$expected_version" ] ||
  fail "daprd reports version $version, expected $expected_version"

# Standalone mode needs no control plane; assert the real sidecar APIs.
docker run --name "$container" -d --read-only --user 65532 --tmpfs /tmp \
  -p 127.0.0.1::3500 "$image" --app-id verity-test --dapr-listen-addresses 0.0.0.0 \
  --dapr-http-port 3500 --enable-api-logging=false >/dev/null
port=$(host_port 3500)
wait_http "http://127.0.0.1:$port/v1.0/healthz/outbound" 204
curl --fail --silent "http://127.0.0.1:$port/v1.0/metadata" >"$work/metadata" ||
  fail 'metadata API request failed'
grep -F '"id":"verity-test"' "$work/metadata" >/dev/null || fail 'metadata API does not report the app id'
grep -F "\"runtimeVersion\":\"$expected_version\"" "$work/metadata" >/dev/null ||
  fail 'metadata API does not report the runtime version'
code=$(curl --silent --output /dev/null --write-out '%{http_code}' \
  "http://127.0.0.1:$port/v1.0/state/missing-store/key")
[ "$code" = 500 ] || [ "$code" = 400 ] || fail "unknown state store returned $code"
stop_clean
