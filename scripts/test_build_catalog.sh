#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
for image in preserved-1 replaced-1 added-1; do
  mkdir -p "$work/scans/scan-$image"
  printf '%s\n' '{}' > "$work/scans/scan-$image/scan-amd64.json"
done
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

python3 "$root/scripts/gen_matrix.py" --all > "$work/expected-images.json"
jq '{images: [.include[] | {
  name,
  version: .tag_version,
  track,
  description,
  digest: ("sha256:" + ("e" * 64)),
  tags: (.tag_version + ",latest"),
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
jq -e --slurp '
  (.[0].images | map([.name, .version]) | sort) ==
  (.[1].include | map([.name, .tag_version]) | sort)
' "$work/catalog.json" "$work/expected-images.json" >/dev/null
