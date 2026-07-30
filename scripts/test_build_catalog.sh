#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/scans/scan-demo-1"
printf '%s\n' '{}' > "$work/scans/scan-demo-1/scan-demo-amd64.json"
cat > "$work/report.json" <<'EOF'
{"images":[{"name":"demo","version":"1","track":"wolfi","description":"Demo image.","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","tags":"1,latest","scan":{"all":{"high":1},"fixable":0}}]}
EOF

python3 "$root/scripts/build_catalog.py" "$work/report.json" "$work/scans" "" \
  "$work/catalog.json" 1 https://github.com/tektum/verity-images/actions/runs/1 \
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 2026-07-30T00:00:00Z
check-jsonschema --schemafile "$root/docs/catalog.schema.json" "$work/catalog.json"
jq -e '
  .schemaVersion == 2 and
  .policy.cosignMinimumVersion == "3.0.6" and
  .images[0].reference == "ghcr.io/tektum/demo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and
  .images[0].scan.fixable == 0
' "$work/catalog.json" >/dev/null
