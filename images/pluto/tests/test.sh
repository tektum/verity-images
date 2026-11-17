#!/bin/sh
set -eu

# Pluto scans a read-only manifest directory with no network access. A removed
# API must be reported with its replacement and exit status 3, a clean tree must
# exit 0, and a missing path must fail.

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*- pluto=\([0-9][0-9.]*\)-r[0-9][0-9]*$/\1/p' \
  "$(dirname "$0")/../apko.yaml")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ -n "$expected_version" ] || fail 'Pluto package version not found'

inspect() {
  docker image inspect --format "$1" "$image"
}

[ "$(inspect '{{.Config.User}}')" = 65532 ] || fail 'unexpected OCI user'
[ "$(inspect '{{json .Config.Entrypoint}}')" = '["/usr/bin/pluto"]' ] ||
  fail "unexpected entrypoint: $(inspect '{{json .Config.Entrypoint}}')"

version=$(docker run --rm --network none "$image" version)
case "$version" in
  "Version:${expected_version} "*) ;;
  *) fail "unexpected Pluto version: $version" ;;
esac

mkdir -p "$work/legacy" "$work/clean"
cat >"$work/legacy/deployment.yaml" <<'EOF'
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: legacy
EOF
cat >"$work/clean/deployment.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: current
EOF
chmod -R a+rX "$work"

status=0
report=$(docker run --rm --network none -v "$work:/work:ro" "$image" \
  detect-files -d /work/legacy -o json --target-versions k8s=v1.30.0) || status=$?
[ "$status" = 3 ] || fail "removed API scan exited $status, expected 3"
printf '%s\n' "$report" | grep -q '"name":"legacy"' || fail "report is missing the legacy resource: $report"
printf '%s\n' "$report" | grep -q '"removed":true' || fail "report did not mark the API removed: $report"
printf '%s\n' "$report" | grep -q '"replacement-api":"apps/v1"' || fail "report is missing the replacement API: $report"

docker run --rm --network none -v "$work:/work:ro" "$image" \
  detect-files -d /work/clean --target-versions k8s=v1.30.0 >/dev/null ||
  fail 'clean manifest scan did not exit 0'

if docker run --rm --network none -v "$work:/work:ro" "$image" detect-files -d /work/missing >/dev/null 2>&1; then
  fail 'missing path unexpectedly succeeded'
fi

printf 'SMOKE PASS version=%s\n' "$expected_version"
