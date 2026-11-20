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

# Untagged Go modules: only allowlisted modules may count a release-tag fix as
# included by commit date. A curl stub serves the module proxy from $work/proxy:
# a file answers 200, a .status file answers its code, anything else 404.
export GO_MODULE_PROXY=https://proxy.test PROXY_ROOT="$work/proxy" CURL_LOG="$work/curl.log"
mkdir -p "$work/bin"
cat > "$work/bin/curl" <<'EOF'
#!/bin/bash
set -euo pipefail
output=
while [[ $# -gt 1 ]]; do
  [[ "$1" == --output ]] && output=$2
  shift
done
printf '%s\n' "$1" >>"$CURL_LOG"
path="$PROXY_ROOT/${1#https://proxy.test/}"
if [[ -f "$path" ]]; then
  cp "$path" "$output"
  printf 200
elif [[ -f "$path.status" ]]; then
  printf '%s' "$(cat "$path.status")"
else
  printf 404
fi
EOF
chmod +x "$work/bin/curl"
export PATH="$work/bin:$PATH"
mkdir -p "$work/proxy/istio.io/istio/@v" "$work/proxy/example.com/untagged/@v"
printf '%s\n' '{"Version":"v0.0.0-20220606151702-83a7f5f171c0"}' \
  > "$work/proxy/istio.io/istio/@v/1.12.8.info"
printf '%s\n' '{"Version":"v0.0.0-20200101000000-0123456789ab"}' \
  > "$work/proxy/example.com/untagged/@v/1.0.0.info"
istio_new=v0.0.0-20260528141032-c51394391cf5
istio_old=v0.0.0-20220101000000-0123456789ab
go_match() {
  jq -cn --arg id "$1" --arg name "$2" --arg version "$3" --arg fixed "$4" --arg related "${5:-CVE-2022-31045}" '
    {artifact:{name:$name,version:$version,type:"go-module"},
     vulnerability:{id:$id,severity:"High",fix:{versions:[$fixed]}},
     relatedVulnerabilities:[{id:$related}]}'
}
go_scan() {
  jq -cs '{matches:.}' > scan-demo-amd64.json
  printf '%s\n' '{"matches":[]}' > scan-demo-arm64.json
}
expect_block() {
  if "$root/scripts/evaluate_scan_gate.sh" demo wolfi "$output" >"$work/gate.log" 2>&1; then
    printf 'untagged Go finding did not block: %s\n' "$1" >&2
    exit 1
  fi
}

# The published GHSA-xwx5 fix 1.12.18 never existed; the shared policy corrects
# it to 1.12.8, which a 2026 Istio pseudo-version includes.
go_match GHSA-xwx5-5c9g-x68x istio.io/istio "$istio_new" 1.12.18 | go_scan
: >"$CURL_LOG"
"$root/scripts/evaluate_scan_gate.sh" demo wolfi "$output" >"$work/gate.log"
jq -e '.fixable == 0 and .all.high == 1' <<<"$(cut -d= -f2- "$output" | tail -n 1)" >/dev/null
grep -qF "GHSA-xwx5-5c9g-x68x in istio.io/istio $istio_new includes fixed release 1.12.8 (v0.0.0-20220606151702-83a7f5f171c0)" \
  "$work/gate.log"
# The semver form is tried first; the bare release tag only after a 404.
[[ "$(cat "$CURL_LOG")" == "https://proxy.test/istio.io/istio/@v/v1.12.8.info
https://proxy.test/istio.io/istio/@v/1.12.8.info" ]]

# A proxy error is not a missing version: the finding stays blocking.
printf 500 > "$work/proxy/istio.io/istio/@v/v1.12.8.info.status"
go_match GHSA-xwx5-5c9g-x68x istio.io/istio "$istio_new" 1.12.18 | go_scan
expect_block "proxy error"
rm "$work/proxy/istio.io/istio/@v/v1.12.8.info.status"

# The correction also applies through the advisory's CVE alias.
go_match CVE-2022-31045 istio.io/istio "$istio_new" 1.12.18 GHSA-xwx5-5c9g-x68x | go_scan
"$root/scripts/evaluate_scan_gate.sh" demo wolfi "$output" >"$work/gate.log"

# A pseudo-version older than the fixed release still blocks.
go_match GHSA-xwx5-5c9g-x68x istio.io/istio "$istio_old" 1.12.18 | go_scan
expect_block "older istio pseudo-version"
jq -e '.fixable == 1' <<<"$(cut -d= -f2- "$output" | tail -n 1)" >/dev/null

# Corrections are advisory-specific and unresolvable fixes fail closed.
go_match GHSA-unrelated istio.io/istio "$istio_new" 1.12.18 | go_scan
expect_block "uncorrected unpublished istio fix"
grep -qF 'fixed release 1.12.18 is not a published module version or release tag' "$work/gate.log"

# A module outside the allowlist fails closed even when its release tag resolves
# to an older commit; the allowlisted finding next to it is still accepted.
{
  go_match GHSA-untagged example.com/untagged "$istio_new" 1.0.0
  go_match GHSA-xwx5-5c9g-x68x istio.io/istio "$istio_new" 1.12.18
} | go_scan
expect_block "untagged module outside the allowlist"
jq -e '.fixable == 1' <<<"$(cut -d= -f2- "$output" | tail -n 1)" >/dev/null
grep -qF "GHSA-untagged in example.com/untagged $istio_new -> 1.0.0" "$work/gate.log"
if grep -qF 'High GHSA-xwx5-5c9g-x68x' "$work/gate.log"; then
  printf 'allowlisted istio finding was reported as a blocker\n' >&2
  exit 1
fi

# Findings that share a fixed release resolve it once.
{
  go_match GHSA-xwx5-5c9g-x68x istio.io/istio "$istio_new" 1.12.18
  go_match GHSA-other istio.io/istio "$istio_new" 1.12.8
} | go_scan
: >"$CURL_LOG"
"$root/scripts/evaluate_scan_gate.sh" demo wolfi "$output" >"$work/gate.log"
[[ $(wc -l <"$CURL_LOG") -eq 2 ]]

# The gate and go/remediate share one allowlist.
grep -qF 'pipelines/go/untagged-release-modules.json' "$root/scripts/evaluate_scan_gate.sh"
grep -qF 'UNTAGGED_POLICY_FILE = "pipelines/go/untagged-release-modules.json"' \
  "$root/pipelines/go/remediate.yaml"
