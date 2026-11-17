#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
recipe="$(dirname "$0")/../melange.yaml"
version=$(sed -n 's/^  version: "\([^"]*\)".*$/\1/p' "$recipe")
commit=$(sed -n 's/^  source-commit: \([0-9a-f]*\)$/\1/p' "$recipe")

trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

command -v jq >/dev/null || fail 'jq is required on the test host'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/vexctl"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

# Every run is offline, read-only, and sees the fixtures read-only.
run() {
  docker run --rm --network none --read-only --user "$(id -u):$(id -g)" \
    -e HOME=/tmp --tmpfs /tmp:rw,mode=1777 \
    -v "$work:/work:ro" -w /work "$image" "$@"
}

run version >"$work/version" 2>&1 || fail 'version failed'
grep -E "^GitVersion: +v$version(\+dirty)?\$" "$work/version" >/dev/null ||
  fail 'version is not embedded'
grep -E "^GitCommit: +$commit\$" "$work/version" >/dev/null ||
  fail 'source commit is not embedded'

run --help >"$work/help" 2>&1 || fail 'help failed'
for sub in create merge filter; do
  grep -E "^  $sub " "$work/help" >/dev/null || fail "help is missing $sub"
done

rc=0
run --definitely-invalid >"$work/invalid" 2>&1 || rc=$?
test "$rc" != 0 || fail 'invalid flag was accepted'
grep -F 'definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'invalid flag diagnostic is missing'

pkg1='pkg:oci/demo@sha256:1111111111111111111111111111111111111111111111111111111111111111'
pkg2='pkg:apk/wolfi/demo@1.0.0-r0?arch=x86_64'

# Document 1: not_affected with a justification.
run create --id=https://example.com/vex/one --author=smoke \
  --product="$pkg1" --vuln=CVE-2023-1111 --status=not_affected \
  --justification=vulnerable_code_not_present >"$work/one.vex.json" ||
  fail 'create (not_affected) failed'
jq -e --arg p "$pkg1" '
  .["@context"] == "https://openvex.dev/ns/v0.2.0" and
  .["@id"] == "https://example.com/vex/one" and
  .author == "smoke" and
  (.statements | length) == 1 and
  .statements[0].vulnerability.name == "CVE-2023-1111" and
  .statements[0].status == "not_affected" and
  .statements[0].justification == "vulnerable_code_not_present" and
  [.statements[0].products[]["@id"]] == [$p]
' "$work/one.vex.json" >/dev/null || fail 'first document has unexpected content'

# Document 2: positional form, fixed status, different product.
run create --id=https://example.com/vex/two "$pkg2" CVE-2023-2222 fixed \
  >"$work/two.vex.json" || fail 'create (fixed) failed'
jq -e --arg p "$pkg2" '
  (.statements | length) == 1 and
  .statements[0].vulnerability.name == "CVE-2023-2222" and
  .statements[0].status == "fixed" and
  [.statements[0].products[]["@id"]] == [$p]
' "$work/two.vex.json" >/dev/null || fail 'second document has unexpected content'

# Invalid status is rejected and produces no document.
rc=0
run create --product="$pkg1" --vuln=CVE-2023-1111 --status=bogus \
  >"$work/bad.vex.json" 2>"$work/bad.err" || rc=$?
test "$rc" != 0 || fail 'invalid status was accepted'
grep -F 'a valid impact status is required' "$work/bad.err" >/dev/null ||
  fail 'invalid status diagnostic is missing'
test ! -s "$work/bad.vex.json" || fail 'invalid status produced a document'

# Merge both documents into one.
run merge --id=https://example.com/vex/merged --author=merger \
  one.vex.json two.vex.json >"$work/merged.vex.json" || fail 'merge failed'
jq -e --arg p1 "$pkg1" --arg p2 "$pkg2" '
  .["@id"] == "https://example.com/vex/merged" and
  .author == "merger" and
  (.statements | length) == 2 and
  ([.statements[].vulnerability.name] | sort) == ["CVE-2023-1111", "CVE-2023-2222"] and
  ([.statements[].products[]["@id"]] | sort) == ([$p1, $p2] | sort) and
  ([.statements[] | select(.vulnerability.name == "CVE-2023-1111") | .status] == ["not_affected"]) and
  ([.statements[] | select(.vulnerability.name == "CVE-2023-2222") | .status] == ["fixed"])
' "$work/merged.vex.json" >/dev/null || fail 'merged document has unexpected content'

# Merge restricted to one product keeps only that statement.
run merge --product="$pkg2" one.vex.json two.vex.json >"$work/only2.vex.json" ||
  fail 'product-scoped merge failed'
jq -e '
  (.statements | length) == 1 and
  .statements[0].vulnerability.name == "CVE-2023-2222"
' "$work/only2.vex.json" >/dev/null || fail 'product-scoped merge did not filter'

# Scanner results: two VEXed CVEs, one unrelated CVE, one GHSA.
cat >"$work/scan.sarif.json" <<'JSON'
{
  "version": "2.1.0",
  "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
  "runs": [
    {
      "tool": {"driver": {"name": "smoke-scanner", "rules": [
        {"id": "CVE-2023-1111-demo"},
        {"id": "CVE-2023-2222-demo"},
        {"id": "CVE-2023-3333-demo"},
        {"id": "GHSA-aaaa-bbbb-cccc"}
      ]}},
      "results": [
        {"ruleId": "CVE-2023-1111-demo", "level": "error", "message": {"text": "one"}},
        {"ruleId": "CVE-2023-2222-demo", "level": "error", "message": {"text": "two"}},
        {"ruleId": "CVE-2023-3333-demo", "level": "error", "message": {"text": "three"}},
        {"ruleId": "GHSA-aaaa-bbbb-cccc", "level": "warning", "message": {"text": "ghsa"}}
      ]
    }
  ]
}
JSON

run filter scan.sarif.json merged.vex.json >"$work/filtered.sarif.json" ||
  fail 'filter failed'
jq -e '
  .version == "2.1.0" and
  (.runs | length) == 1 and
  ([.runs[0].results[].ruleId] | sort) == ["CVE-2023-3333-demo", "GHSA-aaaa-bbbb-cccc"]
' "$work/filtered.sarif.json" >/dev/null || fail 'filter did not suppress the VEXed CVEs'

# A single-document filter only removes that document's vulnerability.
run filter scan.sarif.json one.vex.json >"$work/filtered1.sarif.json" ||
  fail 'single-document filter failed'
jq -e '
  ([.runs[0].results[].ruleId] | sort) ==
    ["CVE-2023-2222-demo", "CVE-2023-3333-demo", "GHSA-aaaa-bbbb-cccc"]
' "$work/filtered1.sarif.json" >/dev/null || fail 'single-document filter is wrong'

# Missing VEX document is an error.
rc=0
run filter scan.sarif.json missing.vex.json >"$work/missing.out" 2>&1 || rc=$?
test "$rc" != 0 || fail 'filter accepted a missing VEX document'

printf 'SMOKE PASS image=%s\n' "$image"
