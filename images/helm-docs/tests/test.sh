#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
config="$(dirname "$0")/../apko.yaml"
version=$(sed -n 's/^    - helm-docs=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
work=$(mktemp -d)
container=

cleanup() {
  [ -z "$container" ] || docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ -n "$version" ] || fail 'could not read the pinned helm-docs version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/helm-docs"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

# helm-docs has no version flag; the Go build info records the main module version.
container=$(docker create "$image")
docker cp "$container:/usr/bin/helm-docs" "$work/helm-docs" >/dev/null ||
  fail 'could not copy the helm-docs binary'
docker rm "$container" >/dev/null
container=
printf 'mod\tgithub.com/norwoodj/helm-docs\tv%s' "$version" >"$work/want"
grep -aF "$(cat "$work/want")" "$work/helm-docs" >/dev/null ||
  fail "binary build info does not report v$version"

rc=0
docker run --rm --network none "$image" --definitely-invalid >"$work/flag" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'unknown flag: --definitely-invalid' "$work/flag" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/flag")"

mkdir -p "$work/charts/demo" "$work/charts/strict"
cat >"$work/charts/demo/Chart.yaml" <<'YAML'
apiVersion: v2
name: demo
description: Demo chart for the Verity smoke test
version: 1.2.3
appVersion: "4.5.6"
type: application
YAML
cat >"$work/charts/demo/values.yaml" <<'YAML'
# -- Number of replicas
replicaCount: 3
image:
  # -- Image repository
  repository: ghcr.io/example/demo
YAML
cp "$work/charts/demo/Chart.yaml" "$work/charts/strict/Chart.yaml"
sed -i 's/^name: demo$/name: strict/' "$work/charts/strict/Chart.yaml"
printf 'undocumented: true\n' >"$work/charts/strict/values.yaml"
chmod -R a+rwX "$work/charts"

# Generate README.md for the demo chart found under /work.
docker run --rm --network none --read-only -v "$work/charts:/work" "$image" \
  --chart-to-generate demo >"$work/run.out" 2>&1 ||
  fail "helm-docs failed: $(cat "$work/run.out")"
readme="$work/charts/demo/README.md"
test -f "$readme" || fail "README.md was not generated: $(cat "$work/run.out")"
# The backticks are literal Markdown, not command substitution.
# shellcheck disable=SC2016
for expected in '# demo' 'Demo chart for the Verity smoke test' \
  '| image.repository | string | `"ghcr.io/example/demo"` | Image repository |' \
  '| replicaCount | int | `3` | Number of replicas |'; do
  grep -Fx -- "$expected" "$readme" >/dev/null ||
    fail "README.md is missing '$expected': $(cat "$readme")"
done
grep -F 'Version-1.2.3' "$readme" >/dev/null || fail 'README.md is missing the chart version badge'
grep -F 'AppVersion-4.5.6' "$readme" >/dev/null || fail 'README.md is missing the app version badge'

test ! -e "$work/charts/strict/README.md" ||
  fail 'the strict chart was generated without being selected'

# Strict mode refuses to document a chart with undocumented values.
docker run --rm --network none --read-only -v "$work/charts:/work" "$image" \
  --documentation-strict-mode --chart-to-generate strict >"$work/strict.out" 2>&1 || true
test ! -e "$work/charts/strict/README.md" ||
  fail 'strict mode generated documentation for undocumented values'
grep -F 'values without documentation' "$work/strict.out" >/dev/null ||
  fail "strict mode diagnostic is missing: $(cat "$work/strict.out")"

printf 'SMOKE PASS\n'
