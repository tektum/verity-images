#!/bin/bash
set -euo pipefail

image_name=${1:?usage: evaluate_scan_gate.sh IMAGE_NAME TRACK OUTPUT}
track=${2:?usage: evaluate_scan_gate.sh IMAGE_NAME TRACK OUTPUT}
output=${3:?usage: evaluate_scan_gate.sh IMAGE_NAME TRACK OUTPUT}
files=("scan-${image_name}-amd64.json" "scan-${image_name}-arm64.json")

final=$(jq -s -c '
  [.[].matches[].vulnerability.severity] |
  group_by(ascii_downcase) |
  map({(.[0] | ascii_downcase): length}) |
  add // {}' "${files[@]}")
count=$(jq -s '[.[].matches[] | select((.vulnerability.fix.versions // []) | length > 0)] | length' \
  "${files[@]}")

case "$track" in
  wolfi)
    summary=$(jq -cn --argjson all "$final" --argjson fixable "$count" \
      '{all:$all,fixable:$fixable}')
    ;;
  patched)
    upstream_files=("scan-${image_name}-upstream-amd64.json" "scan-${image_name}-upstream-arm64.json")
    upstream=$(jq -s -c '
      [.[].matches[].vulnerability.severity] |
      group_by(ascii_downcase) |
      map({(.[0] | ascii_downcase): length}) |
      add // {}' "${upstream_files[@]}")
    delta=$(jq -cn --argjson upstream "$upstream" --argjson final "$final" '
      (($upstream + $final) | keys) |
      map({(.): (($final[.] // 0) - ($upstream[.] // 0))}) |
      add // {}')
    summary=$(jq -cn --argjson upstream "$upstream" --argjson final "$final" \
      --argjson delta "$delta" --argjson fixable "$count" \
      '{upstream:$upstream,final:$final,delta:$delta,fixable:$fixable}')
    ;;
  *)
    printf 'unsupported track: %s\n' "$track" >&2
    exit 2
    ;;
esac

printf 'summary=%s\n' "$summary" >> "$output"
if [[ "$count" -eq 0 ]]; then
  exit 0
fi

blockers=$(jq -s -r '
  [.[].matches[] | select((.vulnerability.fix.versions // []) | length > 0) |
    {id:.vulnerability.id,severity:.vulnerability.severity,
     package:.artifact.name,installed:.artifact.version,
     fixed:((.vulnerability.fix.versions // []) | join(","))}] |
  unique_by(.id,.package,.installed) |
  map("\(.severity) \(.id) in \(.package) \(.installed) -> \(.fixed)") |
  join("; ")' "${files[@]}")
printf '::error title=Fixable vulnerabilities block %s::Found %s fixable findings across %s. Severity summary: %s. %s\n' \
  "$image_name" "$count" "${#files[@]} platforms" "$final" "$blockers"
exit 1
