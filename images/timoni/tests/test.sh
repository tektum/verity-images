#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml" | head -n 1)
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/timoni"]' ] || fail 'unexpected entrypoint'

version=$(docker run --rm --network none "$image" version)
printf '%s\n' "$version" | grep -qx "client: ${expected_version}" || fail "unexpected Timoni version: $version"

cp -R "$(dirname "$0")/module" "$work/smoke"
chmod -R a+rwX "$work"
run() {
  docker run --rm --network none -e HOME=/tmp -v "$work:/work" -w /work "$image" "$@"
}

run mod vet ./smoke >"$work/vet.log" 2>&1 || { cat "$work/vet.log" >&2; fail 'module vet failed'; }

run build verity ./smoke --namespace smoke >"$work/build.yaml" 2>"$work/build.log" ||
  { cat "$work/build.log" >&2; fail 'module build failed'; }
grep -qx 'kind: Deployment' "$work/build.yaml" || fail 'rendered module is missing Deployment'
grep -qx '  namespace: smoke' "$work/build.yaml" || fail 'rendered module ignored namespace'
grep -qx '  replicas: 2' "$work/build.yaml" || fail 'rendered module ignored module values'

printf 'values: replicas: 3\n' >"$work/override.cue"
run build verity ./smoke -n smoke -f override.cue >"$work/override.yaml" 2>"$work/build.log" ||
  { cat "$work/build.log" >&2; fail 'module build with values failed'; }
grep -qx '  replicas: 3' "$work/override.yaml" || fail 'rendered module ignored supplied values'

printf 'values: replicas: "two"\n' >"$work/bad-values.cue"
if run build verity ./smoke -n smoke -f bad-values.cue >/dev/null 2>&1; then
  fail 'invalid values unexpectedly rendered'
fi
if run build verity ./missing -n smoke >/dev/null 2>&1; then
  fail 'missing module unexpectedly rendered'
fi

printf 'SMOKE PASS version=%s\n' "$expected_version"
