#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

cat > scan-demo-amd64.json <<'EOF'
{"matches":[{"artifact":{"name":"openssl","version":"1"},"vulnerability":{"id":"CVE-UNFIXED","severity":"High","fix":{"versions":[]}}}]}
EOF
printf '%s\n' '{"matches":[]}' > scan-demo-arm64.json

output=$work/output
"$root/scripts/evaluate_scan_gate.sh" demo wolfi "$output"
summary=$(cut -d= -f2- "$output")
jq -e '.all.high == 1 and .fixable == 0' <<<"$summary" >/dev/null

cat > scan-demo-arm64.json <<'EOF'
{"matches":[{"artifact":{"name":"zlib","version":"1"},"vulnerability":{"id":"CVE-FIXABLE","severity":"Critical","fix":{"versions":["2"]}}}]}
EOF
if "$root/scripts/evaluate_scan_gate.sh" demo wolfi "$output" >"$work/blocker.log" 2>&1; then
  printf 'fixable finding did not block\n' >&2
  exit 1
fi
summary=$(cut -d= -f2- "$output" | tail -n 1)
jq -e '.all == {"critical":1,"high":1} and .fixable == 1' <<<"$summary" >/dev/null

printf '%s\n' '{"matches":[]}' > scan-demo-amd64.json
printf '%s\n' '{"matches":[]}' > scan-demo-arm64.json
cat > scan-demo-upstream-amd64.json <<'EOF'
{"matches":[{"artifact":{"name":"openssl","version":"1"},"vulnerability":{"id":"CVE-OLD","severity":"High","fix":{"versions":[]}}}]}
EOF
printf '%s\n' '{"matches":[]}' > scan-demo-upstream-arm64.json
"$root/scripts/evaluate_scan_gate.sh" demo patched "$output"
summary=$(cut -d= -f2- "$output" | tail -n 1)
jq -e '.upstream.high == 1 and .final == {} and .delta.high == -1 and .fixable == 0' \
  <<<"$summary" >/dev/null
