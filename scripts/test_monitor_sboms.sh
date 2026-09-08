#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
monitor=$root/scripts/monitor_sboms.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

fail() {
  printf 'test_monitor_sboms: %s\n' "$1" >&2
  exit 1
}

run_monitor() {
  local catalog=$1
  local inventory=$2
  local shard=$3
  local shards=$4
  local output=$5
  PATH="$work/bin:$PATH" "$monitor" "$catalog" "$inventory" "$shard" "$shards" "$output"
}

expect_failure() {
  local message=$1
  shift
  if "$@" >"$work/failure.log" 2>&1; then
    fail "$message"
  fi
}

expect_status() {
  local expected=$1
  local message=$2
  local status
  shift 2
  set +e
  "$@" >"$work/failure.log" 2>&1
  status=$?
  set -e
  [[ $status -eq $expected ]] || fail "$message (expected $expected, got $status)"
}

cat >"$work/bin/cosign" <<'EOF'
#!/bin/bash
set -euo pipefail

{
  printf '%s' "$1"
  printf '\t%s' "${@:2}"
  printf '\n'
} >>"$COSIGN_LOG"

[[ ${1:-} == verify-attestation ]] || exit 90
reference=${8:-}

emit_attestation() {
  local arch=$1
  local created=$2
  local statement
  local payload
  statement=$(jq -cn --arg arch "$arch" --arg created "$created" \
    --arg reference "$reference" '
    {_type:"https://in-toto.io/Statement/v0.1",
     predicateType:"https://spdx.dev/Document",
     subject:[{name:$reference,digest:{sha256:("a" * 64)}}],
     predicate:{spdxVersion:"SPDX-2.3",
                name:("fixture-verity-platform-" + $arch),
                dataLicense:"CC0-1.0",
                SPDXID:"SPDXRef-DOCUMENT",
                creationInfo:{created:$created,
                              creators:["Tool: syft-1.50.0"]},
                packages:[{name:("fixture-" + $arch + "-" + $created),
                           SPDXID:"SPDXRef-Package",
                           versionInfo:"1.0.0"}]}}')
  payload=$(printf '%s' "$statement" | base64 -w0)
  jq -cn --arg payload "$payload" \
    '{payloadType:"application/vnd.in-toto+json",payload:$payload}'
}

case ${ATTESTATION_MODE:-complete} in
  complete)
    emit_attestation amd64 2026-09-07T10:00:00Z
    emit_attestation arm64 2026-09-07T10:00:01Z
    ;;
  missing-arm64)
    emit_attestation amd64 2026-09-07T10:00:00Z
    ;;
  republished-amd64)
    # A reproducible rebuild appends another verified attestation to the same
    # digest. The newest SBOM wins, whatever order the registry returns.
    emit_attestation amd64 2026-08-01T10:00:00Z
    emit_attestation amd64 2026-09-07T10:00:00Z
    emit_attestation amd64 2026-08-15T10:00:00Z
    emit_attestation arm64 2026-09-07T10:00:01Z
    ;;
  *)
    exit 91
    ;;
esac
EOF
chmod +x "$work/bin/cosign"

cat >"$work/bin/grype" <<'EOF'
#!/bin/bash
set -euo pipefail

{
  printf '%s' "$1"
  printf '\t%s' "${@:2}"
  printf '\n'
} >>"$GRYPE_LOG"

if [[ ${1:-} == db && ${2:-} == update && $# -eq 2 ]]; then
  exit 0
fi

[[ $# -eq 5 && $1 == sbom:* && $2 == --output && $3 == json && $4 == --file ]] || exit 92
sbom=${1#sbom:}
[[ -f $sbom ]] || exit 93
jq -e '.packages | type == "array"' "$sbom" >/dev/null || exit 94
cp "$sbom" "$SBOM_COPY_DIR/${sbom##*/}"

cat >"$5" <<'JSON'
{
  "descriptor": {
    "name": "grype",
    "version": "0.116.1",
    "db": {
      "built": "2026-09-08T00:00:00Z",
      "schemaVersion": 6,
      "checksum": "sha256:fixture-database"
    }
  },
  "matches": [
    {
      "artifact": {
        "name": "openssl",
        "version": "3.5.2-r0",
        "type": "apk",
        "locations": [{"path": "/lib/apk/db/installed"}],
        "language": ""
      },
      "vulnerability": {
        "id": "CVE-2026-0001",
        "severity": "High",
        "namespace": "nvd:cpe",
        "fix": {"versions": ["3.5.2-r1"], "state": "fixed"},
        "cvss": [{"version": "3.1", "metrics": {"baseScore": 7.5}}]
      }
    },
    {
      "artifact": {
        "name": "zlib",
        "version": "1.3.1-r1",
        "type": "apk",
        "locations": [{"path": "/lib/apk/db/installed"}],
        "language": ""
      },
      "vulnerability": {
        "id": "CVE-2026-0002",
        "severity": "Low",
        "namespace": "wolfi:distro:wolfi:rolling",
        "fix": {"versions": [], "state": "not-fixed"},
        "cvss": []
      }
    }
  ]
}
JSON
EOF
chmod +x "$work/bin/grype"

for command in gh docker curl; do
  cat >"$work/bin/$command" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "${0##*/}" >>"$FORBIDDEN_LOG"
exit 1
EOF
  chmod +x "$work/bin/$command"
done

export COSIGN_LOG=$work/cosign.log
export GRYPE_LOG=$work/grype.log
export FORBIDDEN_LOG=$work/forbidden.log
export SBOM_COPY_DIR=$work/scanned
mkdir -p "$SBOM_COPY_DIR"
: >"$COSIGN_LOG"
: >"$GRYPE_LOG"
: >"$FORBIDDEN_LOG"

cat >"$work/catalog.json" <<'EOF'
{
  "schemaVersion": 2,
  "publishedAt": "2026-09-08T03:17:00Z",
  "source": {
    "repository": "tektum/verity-images",
    "commit": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
  },
  "images": [
    {
      "name": "alpha",
      "version": "1.0",
      "track": "wolfi",
      "reference": "ghcr.io/tektum/alpha@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "scan": {"all": {"high": 1, "medium": 2}}
    },
    {
      "name": "beta",
      "version": "1.0",
      "track": "wolfi",
      "reference": "ghcr.io/tektum/beta@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "scan": {"all": {"low": 3}}
    },
    {
      "name": "gamma",
      "version": "1.0",
      "track": "wolfi",
      "reference": "ghcr.io/tektum/gamma@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      "digest": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      "scan": {"all": {}}
    },
    {
      "name": "delta",
      "version": "1.0",
      "track": "patched",
      "reference": "ghcr.io/tektum/delta@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
      "digest": "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
      "scan": {"upstream": {"critical": 2}, "final": {"high": 1}, "delta": {"critical": -2, "high": 1}}
    }
  ]
}
EOF

cat >"$work/images.json" <<'EOF'
{
  "include": [
    {"name": "alpha", "tag_version": "1.0", "context": "images/alpha"},
    {"name": "beta", "tag_version": "1.0", "context": "images/beta"},
    {"name": "gamma", "tag_version": "1.0", "context": "images/gamma"},
    {"name": "delta", "tag_version": "1.0", "context": "images/delta"}
  ]
}
EOF

assert_manifest() {
  local output=$1
  local manifest=$output/manifest.json
  local scan
  [[ -f $manifest ]] || fail "monitor did not write $manifest"
  jq -e '
    (.shard == 0 or .shard == 1) and
    .shards == 2 and
    .catalog.schemaVersion == 2 and
    .catalog.publishedAt == "2026-09-08T03:17:00Z" and
    .catalog.source.commit == "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" and
    .catalog.images == 4 and
    (.subjects | length > 0) and
    all(.subjects[];
      .version == "1.0" and
      .reference == ("ghcr.io/tektum/" + .name + "@" + .digest) and
      .context == ("images/" + .name) and
      ([.platforms[].platform] | sort) == ["linux/amd64", "linux/arm64"] and
      (.platforms | length) == 2 and
      all(.platforms[];
        (.scan | test("^scan-[a-z]+-1\\.0-(amd64|arm64)\\.json$")) and
        .attestations == 1 and
        (.created | test("^2026-09-07T10:00:0[01]Z$"))) and
      (if .name == "alpha" then
         .track == "wolfi" and
         .digest == "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and
         .published == {"high": 1, "medium": 2}
       elif .name == "beta" then
         .track == "wolfi" and
         .digest == "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" and
         .published == {"low": 3}
       elif .name == "gamma" then
         .track == "wolfi" and
         .digest == "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" and
         .published == {}
       elif .name == "delta" then
         .track == "patched" and
         .digest == "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd" and
         .published == {"high": 1}
       else false end))
  ' "$manifest" >/dev/null || fail "manifest structure or subject metadata is incorrect in $manifest"

  while IFS= read -r scan; do
    [[ -s $output/$scan ]] || fail "manifest scan file does not exist: $output/$scan"
    jq -e '.descriptor.name == "grype" and (.matches | length == 2)' \
      "$output/$scan" >/dev/null || fail "Grype stub did not write a realistic scan: $output/$scan"
  done < <(jq -r '.subjects[].platforms[].scan' "$manifest")
}

assert_cosign_run() {
  local expected=$1
  local lines
  local command
  local type_flag
  local predicate_type
  local identity_flag
  local identity
  local issuer_flag
  local issuer
  local reference
  local extra
  lines=$(wc -l <"$COSIGN_LOG")
  [[ $lines -eq $expected ]] || fail "cosign ran $lines times, expected $expected"

  while IFS=$'\t' read -r command type_flag predicate_type identity_flag identity \
    issuer_flag issuer reference extra; do
    [[ $command == verify-attestation && $type_flag == --type && $predicate_type == spdxjson ]] ||
      fail "cosign did not use verify-attestation --type spdxjson"
    [[ $identity_flag == --certificate-identity &&
      $identity == https://github.com/tektum/verity-images/.github/workflows/build.yaml@refs/heads/main ]] ||
      fail "cosign used the wrong certificate identity"
    [[ $issuer_flag == --certificate-oidc-issuer &&
      $issuer == https://token.actions.githubusercontent.com ]] ||
      fail "cosign used the wrong OIDC issuer"
    [[ -z $extra ]] || fail "cosign received unexpected arguments"
    [[ $reference =~ ^ghcr\.io/tektum/[a-z]+@sha256:[0-9a-f]{64}$ ]] ||
      fail "cosign was invoked with a mutable or malformed reference: $reference"
    case $reference in
      ghcr.io/tektum/alpha@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa | \
        ghcr.io/tektum/beta@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb | \
        ghcr.io/tektum/gamma@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc | \
        ghcr.io/tektum/delta@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd) ;;
      *) fail "cosign received a reference outside the published catalog: $reference" ;;
    esac
  done <"$COSIGN_LOG"
}

assert_grype_run() {
  local output=$1
  local subjects=$2
  local expected_scans=$((subjects * 2))
  local expected_lines=$((expected_scans + 1))
  local lines
  local db_updates
  local amd64_scans
  local arm64_scans
  local line_number=0
  local target
  local output_flag
  local format
  local file_flag
  local scan_file
  local extra
  lines=$(wc -l <"$GRYPE_LOG")
  [[ $lines -eq $expected_lines ]] ||
    fail "grype ran $lines times, expected one database update and $expected_scans scans"
  db_updates=$(grep -c $'^db\tupdate$' "$GRYPE_LOG" || true)
  [[ $db_updates -eq 1 ]] || fail "grype db update did not run exactly once"
  amd64_scans=$(grep -c 'sbom-amd64.spdx.json' "$GRYPE_LOG" || true)
  arm64_scans=$(grep -c 'sbom-arm64.spdx.json' "$GRYPE_LOG" || true)
  [[ $amd64_scans -eq $subjects && $arm64_scans -eq $subjects ]] ||
    fail "grype did not scan each platform exactly once per subject"

  while IFS=$'\t' read -r target output_flag format file_flag scan_file extra; do
    line_number=$((line_number + 1))
    if ((line_number == 1)); then
      [[ $target == db && $output_flag == update && -z $format ]] ||
        fail "grype db update did not run before the scans"
      continue
    fi
    [[ $target == sbom:*/sbom-*.spdx.json && $output_flag == --output &&
      $format == json && $file_flag == --file && -z $extra ]] ||
      fail "grype scan did not use an SBOM target and --output json"
    [[ $scan_file == "$output"/scan-*.json && -s $scan_file ]] ||
      fail "grype scan output was not written below $output"
  done <"$GRYPE_LOG"
}

run_happy_shard() {
  local shard=$1
  local output=$2
  local expected_subjects=$3
  : >"$COSIGN_LOG"
  : >"$GRYPE_LOG"
  run_monitor "$work/catalog.json" "$work/images.json" "$shard" 2 "$output"
  assert_manifest "$output"
  assert_cosign_run "$expected_subjects"
  assert_grype_run "$output" "$expected_subjects"
}

run_happy_shard 0 "$work/shard-0" 1
run_happy_shard 1 "$work/shard-1" 3

jq -e --slurp '
  ([.[0].subjects[] | (.name + "@" + .version)] | sort) as $zero |
  ([.[1].subjects[] | (.name + "@" + .version)] | sort) as $one |
  (($zero + $one) | length) == 4 and
  (($zero + $one) | unique | length) == 4 and
  (($zero + $one) | sort) == ["alpha@1.0", "beta@1.0", "delta@1.0", "gamma@1.0"]
' "$work/shard-0/manifest.json" "$work/shard-1/manifest.json" >/dev/null ||
  fail "the two shards were not disjoint or did not cover all catalog images"
[[ ! -s $FORBIDDEN_LOG ]] || fail "monitor invoked gh, docker, or curl on the happy path"

first_subjects=$(jq -c '[.subjects[] | [.name, .version]]' "$work/shard-0/manifest.json")
run_happy_shard 0 "$work/shard-0-repeat" 1
repeat_subjects=$(jq -c '[.subjects[] | [.name, .version]]' "$work/shard-0-repeat/manifest.json")
[[ $first_subjects == "$repeat_subjects" ]] || fail "shard membership changed between identical runs"
[[ ! -s $FORBIDDEN_LOG ]] || fail "monitor invoked gh, docker, or curl while checking shard stability"

jq '(.include[] | select(.name == "gamma")) |= del(.context)' \
  "$work/images.json" >"$work/missing-context.json"
expect_failure "catalog image without an inventory context was accepted" \
  run_monitor "$work/catalog.json" "$work/missing-context.json" 0 2 "$work/no-context"

export ATTESTATION_MODE=missing-arm64
expect_failure "attestation without an arm64 SPDX predicate was accepted" \
  run_monitor "$work/catalog.json" "$work/images.json" 0 2 "$work/missing-arm64"

# Republication keeps every earlier attestation on the same digest, so the
# monitor must evaluate the newest SBOM instead of failing or guessing.
export ATTESTATION_MODE=republished-amd64
rm -f "$SBOM_COPY_DIR"/*
run_monitor "$work/catalog.json" "$work/images.json" 0 2 "$work/republished"
unset ATTESTATION_MODE
jq -e '
  all(.subjects[].platforms[];
    (if .platform == "linux/amd64"
     then .attestations == 3 and .created == "2026-09-07T10:00:00Z"
     else .attestations == 1 and .created == "2026-09-07T10:00:01Z" end))
' "$work/republished/manifest.json" >/dev/null ||
  fail "monitor did not record the newest amd64 attestation of three"
jq -e '.packages[0].name == "fixture-amd64-2026-09-07T10:00:00Z"' \
  "$SBOM_COPY_DIR/sbom-amd64.spdx.json" >/dev/null ||
  fail "monitor scanned an SBOM other than the newest amd64 attestation"

jq '.schemaVersion = 1' "$work/catalog.json" >"$work/wrong-schema.json"
expect_failure "catalog schemaVersion other than 2 was accepted" \
  run_monitor "$work/wrong-schema.json" "$work/images.json" 0 2 "$work/wrong-schema"
jq '.images = []' "$work/catalog.json" >"$work/empty-catalog.json"
expect_failure "catalog with an empty images array was accepted" \
  run_monitor "$work/empty-catalog.json" "$work/images.json" 0 2 "$work/empty-catalog"
printf '%s\n' '{"include":[]}' >"$work/empty-inventory.json"
expect_failure "inventory with an empty include array was accepted" \
  run_monitor "$work/catalog.json" "$work/empty-inventory.json" 0 2 "$work/empty-inventory"
jq 'del(.images[0].scan)' "$work/catalog.json" >"$work/missing-scan.json"
expect_failure "catalog image without publication scan counts was accepted" \
  run_monitor "$work/missing-scan.json" "$work/images.json" 0 2 "$work/missing-scan"
grep -Fq 'catalog image alpha 1.0 has no publication scan counts' "$work/failure.log" ||
  fail "missing publication scan counts did not produce a useful error"


empty_shard=
for candidate in {0..15}; do
  set +e
  run_monitor "$work/catalog.json" "$work/images.json" "$candidate" 16 \
    "$work/empty-shard-$candidate" >"$work/empty-shard.log" 2>&1
  status=$?
  set -e
  if [[ $status -eq 0 ]]; then
    continue
  fi
  if grep -Fq 'Empty monitor shard' "$work/empty-shard.log"; then
    empty_shard=$candidate
    break
  fi
  fail "shard $candidate failed for a reason other than selecting no images"
done
[[ -n $empty_shard ]] || fail "monitor did not report any empty shard"

expect_status 2 "SHARD equal to SHARDS did not exit 2" \
  run_monitor "$work/catalog.json" "$work/images.json" 2 2 "$work/bad-shard-range"
expect_status 2 "non-numeric SHARD did not exit 2" \
  run_monitor "$work/catalog.json" "$work/images.json" invalid 2 "$work/bad-shard-text"
expect_status 2 "SHARDS=0 did not exit 2" \
  run_monitor "$work/catalog.json" "$work/images.json" 0 0 "$work/bad-shard-count"

printf 'passed scripts/test_monitor_sboms.sh\n'
