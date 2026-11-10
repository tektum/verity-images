#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
cli=/operator
work=$(mktemp -d)

cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
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
docker run --rm --network none --entrypoint /usr/bin/operator "$image" --help >"$work/help" 2>&1 || true
grep -F -e '--healthz-port' -e '-healthz-port' "$work/help" >/dev/null ||
  { head -n 5 "$work/help" >&2; fail 'operator help is missing the healthz port flag'; }

if docker run --rm --network none --read-only "$image" --definitely-invalid \
  >"$work/invalid" 2>&1; then
  fail 'unknown flag unexpectedly succeeded'
fi
grep -F -e 'unknown flag: --definitely-invalid' \
  -e 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'unknown flag diagnostic is missing'

# Without a cluster the operator must fail with a readable configuration error.
if docker run --rm --network none --read-only "$image" --kubeconfig /definitely-missing \
  >"$work/startup" 2>&1; then
  fail 'operator started without a kubeconfig'
fi
grep -F 'unable to get controller runtime configuration' "$work/startup" >/dev/null ||
  fail 'missing kubeconfig diagnostic is missing'
grep -F "version $expected_version" "$work/startup" >/dev/null ||
  fail "startup log does not report version $expected_version"
