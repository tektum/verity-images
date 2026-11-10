#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
name=dapr-injector
container="verity-$name-test-$$"
cli=/injector
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
docker run --rm --network none --entrypoint /usr/bin/injector "$image" --help >"$work/help" 2>&1 || true
grep -F -e '--healthz-port' -e '-healthz-port' "$work/help" >/dev/null ||
  fail 'injector help is missing the healthz port flag'

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

# The injector is configured by environment; a missing sidecar image must be reported.
if docker run --rm --network none --read-only "$image" >"$work/no-env" 2>&1; then
  fail 'injector started without its sidecar image setting'
fi
grep -F 'required key SIDECAR_IMAGE missing value' "$work/no-env" >/dev/null ||
  fail 'missing sidecar image diagnostic is missing'
grep -F "version $expected_version" "$work/no-env" >/dev/null ||
  fail "startup log does not report version $expected_version"
