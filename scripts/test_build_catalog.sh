#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
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
jq -e '.include | length == 28' "$work/expected-images.json" >/dev/null
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
