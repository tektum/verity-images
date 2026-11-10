#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
recipe="$(dirname "$0")/../melange.yaml"
version=$(sed -n 's/^  version: "\([^"]*\)".*$/\1/p' "$recipe")

trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/syft"]' || fail 'unexpected entrypoint'

run() {
  docker run --rm --network none --read-only --user "$(id -u):$(id -g)" \
    -e HOME=/tmp --tmpfs /tmp:rw,mode=1777 \
    -v "$work:/work:ro" -w /work "$image" "$@"
}

run version >"$work/version" 2>&1 || fail 'version failed'
grep -E "^Version: +${version}\$" "$work/version" >/dev/null ||
  fail 'version is not embedded'
grep -E '^GitCommit: +[0-9a-f]{40}$' "$work/version" >/dev/null ||
  fail 'source commit is not embedded'

run --help >"$work/help" 2>&1 || fail 'help failed'
grep -F 'Usage:' "$work/help" >/dev/null || fail 'help is missing usage text'

rc=0
run --definitely-invalid >"$work/invalid" 2>&1 || rc=$?
test "$rc" != 0 || fail 'invalid argument unexpectedly succeeded'
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'invalid argument diagnostic is missing'

# Fixture project with one Go module and one Python requirement. The directory
# must be world readable because the container runs as the host uid.
mkdir "$work/project" "$work/empty"
printf 'module example.invalid/app\n\ngo 1.22\n\nrequire github.com/google/uuid v1.6.0\n' \
  >"$work/project/go.mod"
printf 'github.com/google/uuid v1.6.0 h1:NIvaJDMOsjHA8n1jAhLSgzrAzy1Hgr+hNrb57e+94F0=\n' \
  >"$work/project/go.sum"
printf 'flask==2.0.1\n' >"$work/project/requirements.txt"

# SPDX SBOM: exit 0 and the fixture packages are listed with their versions.
run dir:/work/project -o spdx-json -q >"$work/spdx.json" 2>"$work/spdx.err" ||
  fail 'spdx scan failed'
grep -F '"spdxVersion":"SPDX-2.3"' "$work/spdx.json" >/dev/null ||
  fail 'output is not an SPDX 2.3 document'
grep -F "\"Tool: syft-${version}\"" "$work/spdx.json" >/dev/null ||
  fail 'SBOM does not name this syft version'
grep -F '"name":"flask"' "$work/spdx.json" >/dev/null ||
  fail 'python package is missing from the SBOM'
grep -F '"versionInfo":"2.0.1"' "$work/spdx.json" >/dev/null ||
  fail 'python package version is missing from the SBOM'
grep -F '"name":"github.com/google/uuid"' "$work/spdx.json" >/dev/null ||
  fail 'go module is missing from the SBOM'
grep -F 'pkg:golang/github.com/google/uuid@v1.6.0' "$work/spdx.json" >/dev/null ||
  fail 'go module purl is missing from the SBOM'

# CycloneDX and the native JSON format come from the same scan.
run dir:/work/project -o cyclonedx-json -q >"$work/cdx.json" ||
  fail 'cyclonedx scan failed'
grep -F '"bomFormat":"CycloneDX"' "$work/cdx.json" >/dev/null ||
  fail 'output is not a CycloneDX document'
run dir:/work/project -o syft-table -q >"$work/table.out" ||
  fail 'table scan failed'
grep -E '^flask +2\.0\.1 +python' "$work/table.out" >/dev/null ||
  fail 'table output is missing the python package'

# An empty directory has no packages and still exits 0.
run dir:/work/empty -q >"$work/empty.out" 2>&1 || fail 'empty directory scan failed'
grep -F 'No packages discovered' "$work/empty.out" >/dev/null ||
  fail 'empty directory result is missing'

# A missing path is an error.
rc=0
run dir:/work/missing -q >"$work/missing.out" 2>&1 || rc=$?
test "$rc" != 0 || fail 'missing path unexpectedly succeeded'

printf 'SMOKE PASS image=%s\n' "$image"
