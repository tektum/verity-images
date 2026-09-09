#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
for image in preserved-1 replaced-1 added-1; do
  mkdir -p "$work/scans/scan-$image"
  printf '%s\n' '{}' > "$work/scans/scan-$image/scan-amd64.json"
done

rejects_report() {
  local report=$1
  local expected=$2
  if python3 "$root/scripts/build_catalog.py" "$report" "$work/scans" "" \
    "$work/rejected.json" 4 https://github.com/tektum/verity-images/actions/runs/4 \
    dddddddddddddddddddddddddddddddddddddddd 2026-08-02T00:00:00Z 2>"$work/error"; then
    printf 'invalid report was accepted: %s\n' "$report" >&2
    exit 1
  fi
  grep -Fq "$expected" "$work/error"
}

printf 'Info: Running script "python3"\n%s\n' \
  '{"images":[]}' > "$work/devbox-stdout-report.json"
rejects_report "$work/devbox-stdout-report.json" 'invalid JSON in build report'

printf '%s\n%s\n' '{"images":[]}' '{"images":[]}' > "$work/multiple-documents-report.json"
rejects_report "$work/multiple-documents-report.json" 'invalid JSON in build report'

printf '%s\ntrailing log\n' '{"images":[]}' > "$work/trailing-log-report.json"
rejects_report "$work/trailing-log-report.json" 'invalid JSON in build report'

printf '{"images":' > "$work/malformed-report.json"
rejects_report "$work/malformed-report.json" 'invalid JSON in build report'

printf '%s\n' '{"images":[{"name":"image","version":"1"}]}' > "$work/invalid-fields-report.json"
rejects_report "$work/invalid-fields-report.json" 'invalid build report'

printf '%s\n' '{"images":[{"name":"image","version":"1","track":"wolfi","description":"Image.","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","tags":"1,latest","scan":{"all":{},"fixable":0},"category":"Not A Real Category"}]}' \
  > "$work/invalid-category-report.json"
rejects_report "$work/invalid-category-report.json" 'image category is invalid'

mkdir "$work/single-scan"
printf '%s\n' '{}' > "$work/single-scan/scan-single-amd64.json"
cat > "$work/single-report.json" <<'EOF'
{"images":[{"name":"single","version":"1","track":"wolfi","description":"Single image.","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","tags":"1,latest","scan":{"all":{},"fixable":0}}]}
EOF
python3 "$root/scripts/build_catalog.py" "$work/single-report.json" "$work/single-scan" "" \
  "$work/single-catalog.json" 0 https://github.com/tektum/verity-images/actions/runs/0 \
  0000000000000000000000000000000000000000 2026-07-29T00:00:00Z
jq -e '.images | map([.name, .version]) == [["single", "1"]]' "$work/single-catalog.json" >/dev/null
jq -e '.images[0] | has("category") | not' "$work/single-catalog.json" >/dev/null
check-jsonschema --schemafile "$root/docs/catalog.schema.json" "$work/single-catalog.json"

mkdir "$work/categorized-scan"
printf '%s\n' '{}' > "$work/categorized-scan/scan-categorized-amd64.json"
cat > "$work/categorized-report.json" <<'EOF'
{"images":[{"name":"categorized","version":"1","track":"wolfi","description":"Categorized image.","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","tags":"1,latest","scan":{"all":{},"fixable":0},"category":"Base & Utilities"}]}
EOF
python3 "$root/scripts/build_catalog.py" "$work/categorized-report.json" "$work/categorized-scan" "" \
  "$work/categorized-catalog.json" 0 https://github.com/tektum/verity-images/actions/runs/0 \
  0000000000000000000000000000000000000000 2026-07-29T00:00:00Z
jq -e '.images[0].category == "Base & Utilities"' "$work/categorized-catalog.json" >/dev/null
check-jsonschema --schemafile "$root/docs/catalog.schema.json" "$work/categorized-catalog.json"
mv "$work/single-scan/scan-single-amd64.json" "$work/single-scan/scan-wrong-amd64.json"
if python3 "$root/scripts/build_catalog.py" "$work/single-report.json" "$work/single-scan" "" \
  "$work/rejected.json" 0 https://github.com/tektum/verity-images/actions/runs/0 \
  0000000000000000000000000000000000000000 2026-07-29T00:00:00Z 2>/dev/null; then
  printf '%s\n' 'mismatched direct scan artifact was accepted' >&2
  exit 1
fi

cat > "$work/report.json" <<'EOF'
{"images":[{"name":"preserved","version":"1","track":"wolfi","description":"Preserved image.","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","tags":"1,latest","scan":{"all":{},"fixable":0}},{"name":"replaced","version":"1","track":"wolfi","description":"Old image.","digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","tags":"1,latest","scan":{"all":{},"fixable":0}}]}
EOF

python3 "$root/scripts/build_catalog.py" "$work/report.json" "$work/scans" "" \
  "$work/previous.json" 1 https://github.com/tektum/verity-images/actions/runs/1 \
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 2026-07-30T00:00:00Z

cat > "$work/report.json" <<'EOF'
{"images":[{"name":"replaced","version":"1","track":"wolfi","description":"New image.","digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","tags":"1,latest","scan":{"all":{},"fixable":0}},{"name":"added","version":"1","track":"wolfi","description":"Added image.","digest":"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","tags":"1,latest","scan":{"all":{},"fixable":0}}]}
EOF

python3 "$root/scripts/build_catalog.py" "$work/report.json" "$work/scans" "$work/previous.json" \
  "$work/catalog.json" 2 https://github.com/tektum/verity-images/actions/runs/2 \
  bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 2026-07-31T00:00:00Z
check-jsonschema --schemafile "$root/docs/catalog.schema.json" "$work/catalog.json"
jq -e '
  .schemaVersion == 2 and
  .policy.cosignMinimumVersion == "3.0.6" and
  [.images[].name] == ["added", "preserved", "replaced"] and
  ([.images[] | select(.name == "replaced")] | length) == 1 and
  (.images[] | select(.name == "preserved").digest) == "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and
  (.images[] | select(.name == "replaced").digest) == "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
' "$work/catalog.json" >/dev/null
jq -e '
  (.images[] | select(.name == "replaced") | .inputDigest) ==
    "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" and
  (.images[] | select(.name == "replaced") | .runId) == "2" and
  (.images[] | select(.name == "preserved") | .runId) == "1"
' "$work/catalog.json" >/dev/null

# A serialized catalog run must fold every missed build report in run order.
# Processing only the second batch reproduces the eviction bug by dropping X.
mkdir -p "$work/reconcile-scans-x/scan-x-1" "$work/reconcile-scans-y/scan-y-1"
printf '%s\n' '{}' > "$work/reconcile-scans-x/scan-x-1/scan-amd64.json"
printf '%s\n' '{}' > "$work/reconcile-scans-y/scan-y-1/scan-amd64.json"
cat > "$work/reconcile-report-x.json" <<'EOF'
{"images":[{"name":"x","version":"1","track":"wolfi","description":"Reconciled X.","digest":"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","tags":"1,latest","scan":{"all":{},"fixable":0}}]}
EOF
cat > "$work/reconcile-report-y.json" <<'EOF'
{"images":[{"name":"y","version":"1","track":"wolfi","description":"Reconciled Y.","digest":"sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff","tags":"1,latest","scan":{"all":{},"fixable":0}}]}
EOF
python3 "$root/scripts/build_catalog.py" "$work/reconcile-report-y.json" \
  "$work/reconcile-scans-y" "$work/previous.json" "$work/evicted-catalog.json" \
  11 https://github.com/tektum/verity-images/actions/runs/11 \
  2222222222222222222222222222222222222222 2026-08-11T00:00:00Z
jq -e '
  ([.images[] | select(.name == "x")] | length == 0) and
  ([.images[] | select(.name == "y")] | length == 1)
' "$work/evicted-catalog.json" >/dev/null
jq --sort-keys --slurp '.[0] * {source: .[1].source}' \
  "$work/evicted-catalog.json" "$work/previous.json" > "$work/pinned-catalog.json"
jq -e '.source.runId == "1" and any(.images[]; .name == "y")' \
  "$work/pinned-catalog.json" >/dev/null
current="$work/pinned-catalog.json"
for run_id in 10 11; do
  if [[ "$run_id" == 10 ]]; then
    report="$work/reconcile-report-x.json"
    scans="$work/reconcile-scans-x"
    source=1111111111111111111111111111111111111111
  else
    report="$work/reconcile-report-y.json"
    scans="$work/reconcile-scans-y"
    source=2222222222222222222222222222222222222222
  fi
  output="$work/reconciled-${run_id}.json"
  python3 "$root/scripts/build_catalog.py" "$report" "$scans" "$current" "$output" \
    "$run_id" "https://github.com/tektum/verity-images/actions/runs/${run_id}" \
    "$source" "2026-08-${run_id}T00:00:00Z"
  current=$output
done
jq -e '
  (.source.runId == "11") and
  ([.images[] | select(.name == "x" and .digest == "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee")] | length == 1) and
  ([.images[] | select(.name == "y" and .digest == "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")] | length == 1)
' "$current" >/dev/null

# A later-completing rerun of an older run ID must win over a higher run ID.
mkdir -p "$work/order-scans-10/scan-shared-1" "$work/order-scans-11/scan-shared-1"
printf '%s\n' '{}' > "$work/order-scans-10/scan-shared-1/scan-amd64.json"
printf '%s\n' '{}' > "$work/order-scans-11/scan-shared-1/scan-amd64.json"
cat > "$work/order-report-10.json" <<'EOF'
{"images":[{"name":"shared","version":"1","track":"wolfi","description":"Later rerun.","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","tags":"1,latest","scan":{"all":{},"fixable":0}}]}
EOF
cat > "$work/order-report-11.json" <<'EOF'
{"images":[{"name":"shared","version":"1","track":"wolfi","description":"Earlier higher ID.","digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","tags":"1,latest","scan":{"all":{},"fixable":0}}]}
EOF
python3 "$root/scripts/build_catalog.py" "$work/order-report-11.json" "$work/order-scans-11" \
  "$work/previous.json" "$work/order-first.json" 11 \
  https://github.com/tektum/verity-images/actions/runs/11 \
  2222222222222222222222222222222222222222 2026-09-09T02:00:00Z
python3 "$root/scripts/build_catalog.py" "$work/order-report-10.json" "$work/order-scans-10" \
  "$work/order-first.json" "$work/order-final.json" 10 \
  https://github.com/tektum/verity-images/actions/runs/10 \
  1111111111111111111111111111111111111111 2026-09-09T03:00:00Z
jq -e '
  (.images[] | select(.name == "shared").runId) == "10" and
  (.images[] | select(.name == "shared").digest) == "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
' "$work/order-final.json" >/dev/null
jq '.source.consumedRuns = {"10": 2, "11": 1}' \
  "$work/order-final.json" > "$work/ledger-catalog.json"
check-jsonschema --schemafile "$root/docs/catalog.schema.json" "$work/ledger-catalog.json"

python3 "$root/scripts/gen_matrix.py" --all > "$work/expected-images.json"
cat > "$work/devbox" <<'EOF'
#!/bin/sh
printf 'Info: creating Python environment\n'
[ "$1" = --quiet ] && shift
[ "$1" = run ] && shift
[ "$1" = -- ] && shift
exec "$@"
EOF
chmod +x "$work/devbox"
ln -s "$root/scripts" "$work/scripts"
(
  cd "$work"
  PATH="$work:$PATH" devbox --quiet run -- sh -c 'python3 scripts/gen_matrix.py --all > expected-images.json' > cold-banner.log
)
grep -Fx 'Info: creating Python environment' "$work/cold-banner.log"
jq '.include += [{name: "latest-selector-fixture", tag_version: "latest", track: "wolfi", description: "Latest selector fixture."}]' \
  "$work/expected-images.json" > "$work/expected-images-with-fixture.json"
mv "$work/expected-images-with-fixture.json" "$work/expected-images.json"
jq '{images: [.include[] | {
  name,
  version: .tag_version,
  track,
  description,
  digest: ("sha256:" + ("e" * 64)),
  tags: (if .tag_version == "latest" then "latest,latest-20260801" else .tag_version + ",latest" end),
  scan: {all: {}, fixable: 0}
}]}' "$work/expected-images.json" > "$work/report.json"
while IFS=$'\t' read -r name version; do
  mkdir -p "$work/all-scans/scan-$name-$version"
  printf '%s\n' '{}' > "$work/all-scans/scan-$name-$version/scan-amd64.json"
done < <(jq -r '.include[] | [.name, .tag_version] | @tsv' "$work/expected-images.json")

python3 "$root/scripts/build_catalog.py" "$work/report.json" "$work/all-scans" "" \
  "$work/catalog.json" 3 https://github.com/tektum/verity-images/actions/runs/3 \
  cccccccccccccccccccccccccccccccccccccccc 2026-08-01T00:00:00Z
check-jsonschema --schemafile "$root/docs/catalog.schema.json" "$work/catalog.json"
jq -e '(.images[] | select(.name == "latest-selector-fixture").tags) == ["latest", "latest-20260801"]' \
  "$work/catalog.json" >/dev/null
jq -e --slurp '
  (.[0].images | map([.name, .version]) | sort) ==
  (.[1].include | map([.name, .tag_version]) | sort)
' "$work/catalog.json" "$work/expected-images.json" >/dev/null
jq -e '.images | length > 100' "$work/catalog.json" >/dev/null
jq -e '.images | any(.name == "static" and .version == "wolfi")' "$work/catalog.json" >/dev/null
jq '.images = .images[:5]' "$work/catalog.json" > "$work/partial-catalog.json"
jq -e --slurp --from-file "$root/scripts/catalog_inventory.jq" \
  "$work/partial-catalog.json" "$work/expected-images.json" >/dev/null
jq '.images += [{name: "unknown", version: "1"}]' "$work/partial-catalog.json" > "$work/unknown-catalog.json"
if jq -e --slurp --from-file "$root/scripts/catalog_inventory.jq" \
  "$work/unknown-catalog.json" "$work/expected-images.json" >/dev/null; then
  printf '%s\n' 'unknown catalog image unexpectedly passed partial inventory validation' >&2
  exit 1
fi

# A version-authority change must not prune a published entry before its
# replacement build exists, and must prune it once the replacement is published.
cat > "$work/authority-expected.json" <<'EOF'
{"include":[{"name":"authority","tag_version":"2.0"},{"name":"other","tag_version":"1.0"}]}
EOF
mkdir -p "$work/authority-scans/scan-other-1.0" "$work/authority-scans/scan-authority-1.0" \
  "$work/authority-scans/scan-authority-2.0"
printf '%s\n' '{}' > "$work/authority-scans/scan-other-1.0/scan-amd64.json"
printf '%s\n' '{}' > "$work/authority-scans/scan-authority-1.0/scan-amd64.json"
printf '%s\n' '{}' > "$work/authority-scans/scan-authority-2.0/scan-amd64.json"
image_report() {
  jq -n --arg name "$1" --arg version "$2" --arg digest "$3" \
    '{name:$name,version:$version,track:"wolfi",description:"Authority image.",
      digest:("sha256:" + ($digest * 64)),tags:($version + ",latest"),scan:{all:{},fixable:0}}'
}
jq -n --slurpfile images <(image_report authority 1.0 a) '{images: $images}' > "$work/authority-previous.json"
EXPECTED_IMAGES="$work/authority-expected.json" python3 "$root/scripts/build_catalog.py" \
  "$work/authority-previous.json" "$work/authority-scans" "" "$work/authority-legacy.json" \
  5 https://github.com/tektum/verity-images/actions/runs/5 \
  eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee 2026-08-03T00:00:00Z
jq -e '.images | map([.name, .version]) == [["authority", "1.0"]]' "$work/authority-legacy.json" >/dev/null
jq -e --slurp --from-file "$root/scripts/catalog_inventory.jq" \
  "$work/authority-legacy.json" "$work/authority-expected.json" >/dev/null

jq -n --slurpfile images <(image_report authority 2.0 b; image_report other 1.0 c) '{images: $images}' \
  > "$work/authority-report.json"
EXPECTED_IMAGES="$work/authority-expected.json" python3 "$root/scripts/build_catalog.py" \
  "$work/authority-report.json" "$work/authority-scans" "$work/authority-legacy.json" \
  "$work/authority-catalog.json" 6 https://github.com/tektum/verity-images/actions/runs/6 \
  ffffffffffffffffffffffffffffffffffffffff 2026-08-04T00:00:00Z
jq -e '.images | map([.name, .version]) == [["authority", "2.0"], ["other", "1.0"]]' \
  "$work/authority-catalog.json" >/dev/null
jq -e --slurp --from-file "$root/scripts/catalog_inventory.jq" \
  "$work/authority-catalog.json" "$work/authority-expected.json" >/dev/null

# An explicit empty expected matrix means no image is publishable. It is
# different from unavailable inventory authority and must remove every entry.
printf '%s\n' '{"include":[]}' > "$work/empty-expected.json"
EXPECTED_IMAGES="$work/empty-expected.json" python3 "$root/scripts/build_catalog.py" \
  "$work/authority-report.json" "$work/authority-scans" "$work/authority-legacy.json" \
  "$work/empty-catalog.json" 6 https://github.com/tektum/verity-images/actions/runs/6 \
  ffffffffffffffffffffffffffffffffffffffff 2026-08-04T00:00:00Z
jq -e '.images == []' "$work/empty-catalog.json" >/dev/null

# A retired image name is still pruned outright.
jq -n --slurpfile images <(image_report retired 1.0 a; image_report other 1.0 c) '{images: $images}' \
  > "$work/retired-previous.json"
mkdir -p "$work/authority-scans/scan-retired-1.0"
printf '%s\n' '{}' > "$work/authority-scans/scan-retired-1.0/scan-amd64.json"
EXPECTED_IMAGES="$work/authority-expected.json" python3 "$root/scripts/build_catalog.py" \
  "$work/retired-previous.json" "$work/authority-scans" "" "$work/retired-catalog.json" \
  7 https://github.com/tektum/verity-images/actions/runs/7 \
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 2026-08-05T00:00:00Z
jq -e '.images | map([.name, .version]) == [["other", "1.0"]]' "$work/retired-catalog.json" >/dev/null
