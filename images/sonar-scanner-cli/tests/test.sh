#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([0-9]*\.[0-9]*\.[0-9]*\)\.[0-9]*".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
tmp=$(mktemp -d)
chmod 777 "$tmp"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532 ] ||
  fail 'unexpected image config: User'
[ "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/sonar-scanner"]' ] ||
  fail 'unexpected image config: Entrypoint'
[ "$(docker image inspect "$image" --format '{{.Config.WorkingDir}}')" = /usr/src ] ||
  fail 'unexpected image config: WorkingDir'

docker run --rm "$image" --version >"$tmp/version.log" 2>&1 ||
  fail 'sonar-scanner --version failed'
grep -F "SonarScanner CLI $expected_version" "$tmp/version.log" >/dev/null || {
  cat "$tmp/version.log" >&2
  fail "scanner does not report version $expected_version"
}

# The bundled launcher must find a working JRE.
docker run --rm --entrypoint /usr/lib/jvm/default-jvm/bin/java "$image" -version >"$tmp/java.log" 2>&1 ||
  fail 'bundled JRE does not run'
grep -F 'OpenJDK Runtime Environment' "$tmp/java.log" >/dev/null || fail 'unexpected JRE output'

# An analysis run against an unreachable server proves the launcher, JRE and
# scanner engine start and reach the server query stage with the read-only
# project mounted as the non-root user.
printf 'print(1)\n' >"$tmp/app.py"
if docker run --rm -v "$tmp:/usr/src:ro" "$image" \
  -Dsonar.host.url=http://127.0.0.1:9 -Dsonar.projectKey=verity-smoke \
  -Dsonar.sources=. >"$tmp/scan.log" 2>&1; then
  fail 'scan against an unreachable server unexpectedly succeeded'
fi
grep -F 'Fail to get bootstrap index from server' "$tmp/scan.log" >/dev/null ||
  grep -F 'Failed to query server version' "$tmp/scan.log" >/dev/null || {
  cat "$tmp/scan.log" >&2
  fail 'scan did not reach the server query stage'
}

if docker run --rm "$image" --no-such-flag >"$tmp/invalid.log" 2>&1; then
  fail 'unknown flag unexpectedly succeeded'
fi
grep -F 'Unrecognized option: --no-such-flag' "$tmp/invalid.log" >/dev/null || {
  cat "$tmp/invalid.log" >&2
  fail 'unknown flag error is not readable'
}

printf 'SMOKE PASS image=%s\n' "$image"
