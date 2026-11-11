#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d)

trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
expected_commit=$(awk '$1 == "source-commit:" { print substr($2, 1, 7); exit }' \
  "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'
[ -n "$expected_commit" ] || fail 'could not read the recipe source commit'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/apisix-ingress-controller"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = \
  '["-c","/app/conf/config.yaml"]' || fail 'unexpected command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /app ||
  fail 'unexpected working directory'

docker run --rm --network none --read-only "$image" version --long >"$work/version" 2>&1 ||
  fail 'version command failed'
grep -Fx "Version: $expected_version" "$work/version" >/dev/null ||
  fail "version is not $expected_version"
grep -Fx "Git SHA: $expected_commit" "$work/version" >/dev/null ||
  fail "git sha is not $expected_commit"
grep -E '^Running OS/Arch: linux/(amd64|arm64)$' "$work/version" >/dev/null ||
  fail 'running platform is missing'

docker run --rm --network none --read-only "$image" --help >"$work/help" 2>&1 ||
  fail '--help failed'
for flag in --config-path --controller-name --health-probe-bind-address --metrics-bind-address --log-level; do
  grep -F -e "$flag" "$work/help" >/dev/null || fail "help is missing $flag"
done

if docker run --rm --network none --read-only "$image" --definitely-invalid \
  >"$work/invalid" 2>&1; then
  fail 'invalid flag unexpectedly succeeded'
fi
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'invalid flag diagnostic is missing'

# The default command reads /app/conf/config.yaml, which the image does not ship.
if docker run --rm --network none --read-only "$image" >"$work/noconfig" 2>&1; then
  fail 'start without a configuration file unexpectedly succeeded'
fi
grep -F 'open /app/conf/config.yaml: no such file or directory' "$work/noconfig" >/dev/null ||
  fail 'missing configuration diagnostic is missing'

chmod 755 "$work"
printf 'log_level: bogus\n' >"$work/config.yaml"
chmod 644 "$work/config.yaml"
if docker run --rm --network none --read-only -v "$work:/app/conf:ro" "$image" \
  >"$work/badlevel" 2>&1; then
  fail 'invalid log level unexpectedly succeeded'
fi
grep -F 'unrecognized level: "bogus"' "$work/badlevel" >/dev/null ||
  fail 'invalid log level diagnostic is missing'

# A valid configuration is parsed and logged, then the controller stops because no cluster is
# reachable. A crash loop on startup parsing would not reach this point.
printf 'log_level: info\n' >"$work/config.yaml"
if docker run --rm --network none --read-only -v "$work:/app/conf:ro" "$image" \
  >"$work/nocluster" 2>&1; then
  fail 'start without a cluster unexpectedly succeeded'
fi
grep -F 'controller start configuration' "$work/nocluster" >/dev/null ||
  fail 'valid configuration was not loaded'
grep -F 'unable to load in-cluster config' "$work/nocluster" >/dev/null ||
  fail 'missing in-cluster configuration diagnostic is missing'
if grep -E '^(panic|goroutine )' "$work/nocluster" >/dev/null; then
  fail 'startup without a cluster panicked'
fi

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$expected_version"
