#!/bin/bash
set -euo pipefail

image_name=${1:?usage: evaluate_scan_gate.sh IMAGE_NAME TRACK OUTPUT}
track=${2:?usage: evaluate_scan_gate.sh IMAGE_NAME TRACK OUTPUT}
output=${3:?usage: evaluate_scan_gate.sh IMAGE_NAME TRACK OUTPUT}
files=("scan-${image_name}-amd64.json" "scan-${image_name}-arm64.json")
root=$(cd "$(dirname "$0")/.." && pwd)
# Shared with pipelines/go/remediate.yaml: only these untagged Go modules may
# have an advisory fix counted as included by release-commit date.
policy="$root/pipelines/go/untagged-release-modules.json"
proxy=${GO_MODULE_PROXY:-https://proxy.golang.org}
untagged='^v0\.0\.0-[0-9]{14}-[0-9a-f]{12}$'

# Resolve a release tag to the module version Go selects for it, trying the
# semver form first and then the bare tag (Istio tags omit the v prefix). Only a
# 404 or 410 moves on to the next form; any other failure leaves it unresolved.
resolve_release() {
  local module=$1 fixed=${2#v} escaped query code body
  escaped=$(jq -rn --arg value "$module" '$value | gsub("(?<c>[A-Z])"; "!" + (.c | ascii_downcase))')
  body=$(mktemp)
  for query in "v$fixed" "$fixed"; do
    code=$(curl -sS --retry 5 --retry-delay 5 --max-time 30 --output "$body" --write-out '%{http_code}' \
      "$proxy/$escaped/@v/$query.info") || break
    case "$code" in
      200)
        jq -er '.Version | strings' "$body" || break
        rm -f "$body"
        return
        ;;
      404 | 410) ;;
      *) break ;;
    esac
  done
  rm -f "$body"
  return 1
}
declare -A releases=()

# Allowlisted findings carry their advisory fix corrections from the policy.
candidates=$(jq -s -r --slurpfile policy "$policy" --arg untagged "$untagged" '
  $policy[0].modules as $modules |
  [.[].matches[] |
    select((.vulnerability.fix.versions // []) | length > 0) |
    select(.artifact.type == "go-module" and (.artifact.name as $name | $modules | has($name))) |
    select(.artifact.version | test($untagged)) |
    ([.vulnerability.id] + [.relatedVulnerabilities[]?.id]) as $ids |
    ($modules[.artifact.name]["fix-corrections"] // []) as $corrections |
    {id: .vulnerability.id, package: .artifact.name, installed: .artifact.version,
     fixed: [.vulnerability.fix.versions[] | ltrimstr("v") as $published |
       (first($corrections[] | select((.advisory | IN($ids[])) and (.published | ltrimstr("v")) == $published) |
         .fixed | ltrimstr("v")) // $published)]}] |
  unique_by(.id, .package, .installed)[] |
  [.id, .package, .installed, (.fixed | join(" "))] | @tsv' "${files[@]}")
satisfied='[]'
while IFS=$'\t' read -r id package installed fixes; do
  [[ -n "$id" ]] || continue
  included=true
  details=()
  for fixed in $fixes; do
    if [[ ! -v "releases[$package@$fixed]" ]]; then
      releases["$package@$fixed"]=$(resolve_release "$package" "$fixed") || releases["$package@$fixed"]=
    fi
    release=${releases["$package@$fixed"]}
    if [[ -z "$release" ]]; then
      printf '::warning title=Unresolved release fix::%s in %s %s: fixed release %s is not a published module version or release tag\n' \
        "$id" "$package" "$installed" "$fixed"
      included=false
      break
    fi
    # A release with a real module version always sorts above a v0.0.0 pseudo-version.
    # Pseudo-versions order by commit time, then hash, as in go/remediate.
    if [[ ! "$release" =~ $untagged ]] || ! printf '%s\n%s\n' "$release" "$installed" | LC_ALL=C sort -C; then
      included=false
      break
    fi
    details+=("$fixed ($release)")
  done
  if [[ "$included" == true ]]; then
    printf '::notice title=Untagged Go module includes fix::%s in %s %s includes fixed release %s\n' \
      "$id" "$package" "$installed" "${details[*]}"
    satisfied=$(jq -c --arg id "$id" --arg package "$package" --arg installed "$installed" \
      '. + [[$id, $package, $installed]]' <<<"$satisfied")
  fi
done <<<"$candidates"
# shellcheck disable=SC2016 # jq program, expanded by jq
blocking='def blocking: select((.vulnerability.fix.versions // []) | length > 0) |
  select([.vulnerability.id, .artifact.name, .artifact.version] as $key | any($satisfied[]; . == $key) | not);'

final=$(jq -s -c '
  [.[].matches[].vulnerability.severity] |
  group_by(ascii_downcase) |
  map({(.[0] | ascii_downcase): length}) |
  add // {}' "${files[@]}")
count=$(jq -s --argjson satisfied "$satisfied" "$blocking"'[.[].matches[] | blocking] | length' \
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

blockers=$(jq -s -r --argjson satisfied "$satisfied" "$blocking"'
  [.[].matches[] | blocking |
    {id:.vulnerability.id,severity:.vulnerability.severity,
     package:.artifact.name,installed:.artifact.version,
     fixed:((.vulnerability.fix.versions // []) | join(","))}] |
  unique_by(.id,.package,.installed) |
  map("\(.severity) \(.id) in \(.package) \(.installed) -> \(.fixed)") |
  join("; ")' "${files[@]}")
printf '::error title=Fixable vulnerabilities block %s::Found %s fixable findings across %s. Severity summary: %s. %s\n' \
  "$image_name" "$count" "${#files[@]} platforms" "$final" "$blockers"
exit 1
