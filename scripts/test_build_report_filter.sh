#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
filter=$(awk '
  /jq -e --slurp --arg expected/ { capture=1; next }
  capture && /"\$report" >\/dev\/null/ { exit }
  capture { sub(/^              /, ""); print }
' "$root/.github/workflows/build.yaml")

[ -n "$filter" ]

temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT

accepts() {
  jq -e --slurp --arg expected "$2" --arg event "$3" "$filter" "$1" >/dev/null
}

rejects() {
  if accepts "$1" "$2" "$3" 2>/dev/null; then
    printf 'error: accepted malformed report %s\n' "$1" >&2
    exit 1
  fi
}

cat > "$temporary/published.json" <<'EOF'
{"name":"nginx","version":"1.0","track":"wolfi","description":"Nginx","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","tags":"1.0","scan":{"fixable":0}}
EOF
cat > "$temporary/pull-request.json" <<'EOF'
{"name":"nginx","version":"1.0","track":"wolfi","description":"Nginx","digest":"local","scan":{"fixable":0}}
EOF
cat > "$temporary/unknown-key.json" <<'EOF'
{"name":"nginx","version":"1.0","track":"wolfi","description":"Nginx","digest":"local","scan":{"fixable":0},"unexpected":true}
EOF
cat > "$temporary/invalid-content.json" <<'EOF'
{"name":"nginx","version":"1.0","track":"wolfi","description":"","digest":"local","scan":{"fixable":0}}
EOF
cat > "$temporary/log-pollution.json" <<'EOF'
{"name":"nginx","version":"1.0","track":"wolfi","description":"Nginx","digest":"local","scan":{"fixable":0}}
unexpected log output
EOF

accepts "$temporary/published.json" nginx-1.0 push
accepts "$temporary/pull-request.json" nginx-1.0 pull_request
rejects "$temporary/unknown-key.json" nginx-1.0 pull_request
rejects "$temporary/invalid-content.json" nginx-1.0 pull_request
rejects "$temporary/log-pollution.json" nginx-1.0 pull_request
