#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)

if [[ ${1:-} == --squawk-payload ]]; then
  payload=${2:?usage: monitor_sboms.sh --squawk-payload PAYLOAD}
  repository=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}
  run_url=${RUN_URL:?RUN_URL is required}
  jq -e '
    .schema_version == 1 and
    (.delivery_id | type == "string" and test("^[a-f0-9]{64}$")) and
    (.logical_image_ref | type == "string" and test("@sha256:[a-f0-9]{64}$")) and
    (.package_name | type == "string" and length > 0) and
    (.ecosystem | type == "string" and length > 0) and
    (.version | type == "string" and length > 0) and
    (.vuln_id | type == "string" and length > 0) and
    (.platforms | type == "array" and length > 0) and
    all(.platforms[]; (.platform | test("^linux/(amd64|arm64)$")) and (.image_ref | test("@sha256:[a-f0-9]{64}$")))
  ' "$payload" >/dev/null
  delivery=$(jq -er .delivery_id "$payload")
  title=$(jq -r '"[CVE] \(.package_name)@\(.version) \(.vuln_id)"' "$payload")
  issues=$(gh api --paginate --slurp "repos/${repository}/issues?state=all&per_page=100")
  issue=$(jq -c --arg delivery "$delivery" '[.[][] | select(has("pull_request") | not) | select((.body // "") | contains("<!-- squawk-delivery:" + $delivery + " -->"))] | if length > 1 then error("duplicate Squawk delivery issues") else .[0] // null end' <<<"$issues")
  body=$(mktemp)
  trap 'rm -f "$body"' EXIT
  jq -r --arg run "$run_url" '
    "<!-- squawk-delivery:\(.delivery_id) -->\nSquawk reported **\(.vuln_id)** for `\(.package_name)@\(.version)` in `\(.ecosystem)`.\n\n- Logical image: \(.logical_image_ref)\n- Severity: \(.severity // "unknown")\n- Workflow: \($run)\n\n| Platform | Digest |\n|---|---|\n" + ([.platforms[] | "| \(.platform) | `\(.image_ref)` |"] | join("\n"))
  ' "$payload" > "$body"
  number=$(jq -r '.number // empty' <<<"$issue")
  if [[ -z "$number" ]]; then
    gh issue create --repo "$repository" --title "$title" --body-file "$body"
  else
    [[ $(jq -r .state <<<"$issue") != CLOSED ]] || gh issue reopen "$number" --repo "$repository"
    gh issue edit "$number" --repo "$repository" --body-file "$body"
  fi
  exit 0
fi

catalog=${1:?usage: monitor_sboms.sh CATALOG EXPECTED}
expected=${2:?usage: monitor_sboms.sh CATALOG EXPECTED}
repository=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}
run_url=${RUN_URL:?RUN_URL is required}
summary=${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is required}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

identity=https://github.com/tektum/verity-images/.github/workflows/build.yaml@refs/heads/main
issuer=https://token.actions.githubusercontent.com
jq -e --arg identity "$identity" --arg issuer "$issuer" --slurpfile expected "$expected" '
  .schemaVersion == 2 and
  .policy.certificateIdentity == $identity and
  .policy.certificateIssuer == $issuer and
  (.images | type == "array" and length > 0) and
  all(.images[];
    (.name | type == "string" and test("^[a-z0-9]+([._-][a-z0-9]+)*$")) and
    (.version | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
    (.digest | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
    .reference == ("ghcr.io/tektum/" + .name + "@" + .digest)
  ) and
  ([.images[] | [.name, .version]] | length) ==
    ([.images[] | [.name, .version]] | unique | length) and
  ($expected[0].include | type == "array" and length > 0) and
  ([.images[] | [.name, .version]] | sort) ==
    ([$expected[0].include[] | [.name, .tag_version]] | sort)
' "$catalog" >/dev/null
images_file=$work/images.jsonl
jq -ec '.images[]' "$catalog" > "$images_file"
mapfile -t images < "$images_file"
for image in "${images[@]}"; do
  version=$(jq -er .version <<<"$image")
  digest=$(jq -er .digest <<<"$image")
  reference=$(jq -er .reference <<<"$image")
  raw=$(docker buildx imagetools inspect "${reference%@*}:$version" --raw)
  actual=sha256:$(printf '%s' "$raw" | sha256sum | cut -d' ' -f1)
  [[ "$actual" == "$digest" ]]
done
issues=$(gh api --paginate --slurp "repos/${repository}/issues?state=all&per_page=100" | jq -c '
  [.[][] | select(has("pull_request") | not) | {
    number, title, state: (.state | ascii_upcase), body, author: .user.login
  }]
')
jq -e '
  [.[] | select(
    .author == "github-actions[bot]" and
    ((.body // "") | startswith("<!-- sbom-cve-monitor -->"))
  ) | .title] as $managed |
  ($managed | length) == ($managed | unique | length)
' <<<"$issues" >/dev/null

printf '| Image | Findings | Severity |\n|---|---:|---|\n' >> "$summary"
for index in "${!images[@]}"; do
  image=${images[$index]}
  name=$(jq -er .name <<<"$image")
  version=$(jq -er .version <<<"$image")
  reference=$(jq -er .reference <<<"$image")
  key=$index
  attestation=$work/$key.attestation.json
  scan=$work/$key.json

  cosign verify-attestation --type spdxjson \
    --certificate-identity "$identity" \
    --certificate-oidc-issuer "$issuer" \
    "$reference" > "$attestation"
  predicates_file=$work/$key.predicates.jsonl
  jq -es -c '
    if length == 0 then error("missing SPDX attestation")
    else
      map(.payload | @base64d | fromjson) |
      map(
        if (.predicate.name | endswith("-verity-platform-amd64")) then
          . + {architecture: "amd64"}
        elif (.predicate.name | endswith("-verity-platform-arm64")) then
          . + {architecture: "arm64"}
        else empty
        end
      ) |
      sort_by(.predicate.creationInfo.created) |
      group_by(.architecture) |
      map(last) |
      if ([.[].architecture] | sort) != ["amd64", "arm64"] then
        error("expected amd64 and arm64 SPDX attestations")
      else .[].predicate
      end
    end
  ' "$attestation" > "$predicates_file"
  mapfile -t predicates < "$predicates_file"
  [[ ${#predicates[@]} -eq 2 ]]

  scans=()
  for platform in "${!predicates[@]}"; do
    sbom=$work/$key-$platform.spdx.json
    platform_scan=$work/$key-$platform.json
    printf '%s\n' "${predicates[$platform]}" > "$sbom"
    grype "sbom:$sbom" --config "$root/.grype.yaml" --output json --file "$platform_scan"
    jq -e '.matches | type == "array"' "$platform_scan" >/dev/null
    scans+=("$platform_scan")
  done
  jq -s '{matches: ([.[].matches[] |
    select((.vulnerability.fix.versions // []) | length > 0)] | unique_by(
    .vulnerability.id, .artifact.name, .artifact.version
  ))}' "${scans[@]}" > "$scan"

  count=$(jq '.matches | length' "$scan")
  severities=$(jq -c '
    [.matches[].vulnerability.severity | ascii_downcase] |
    group_by(.) | map({(.[0]): length}) | add // {}
  ' "$scan")
  printf '| %s:%s | %s | %s |\n' "$name" "$version" "$count" "$severities" >> "$summary"
done

for index in "${!images[@]}"; do
  image=${images[$index]}
  name=$(jq -er .name <<<"$image")
  version=$(jq -er .version <<<"$image")
  reference=$(jq -er .reference <<<"$image")
  key=$index
  scan=$work/$key.json
  count=$(jq '.matches | length' "$scan")
  severities=$(jq -c '
    [.matches[].vulnerability.severity | ascii_downcase] |
    group_by(.) | map({(.[0]): length}) | add // {}
  ' "$scan")
  title="[CVE] $name:$version"
  issue=$(jq -c --arg title "$title" '
    [.[] | select(
      .author == "github-actions[bot]" and
      .title == $title and
      ((.body // "") | startswith("<!-- sbom-cve-monitor -->"))
    )] | .[0] // null
  ' <<<"$issues")

  if [[ "$count" -gt 0 ]]; then
    body=$work/$key.md
    {
      printf '<!-- sbom-cve-monitor -->\n'
      printf 'Nightly Grype scan of the verified SPDX SBOM found **%s** vulnerable package matches.\n\n' "$count"
      printf -- '- Image: %s\n- Severity: %s\n- Workflow: %s\n\n' "$reference" "$severities" "$run_url"
      printf '| Severity | Vulnerability | Package | Installed | Fixed versions |\n'
      printf '|---|---|---|---|---|\n'
      jq -r '
        [.matches[] | {
          severity: .vulnerability.severity,
          id: .vulnerability.id,
          package: .artifact.name,
          installed: .artifact.version,
          fixed: ((.vulnerability.fix.versions // []) | join(", "))
        }] | unique_by(.id, .package, .installed) | sort_by(.severity, .id) | .[:100][] |
        "| \(.severity) | \(.id) | \(.package) | \(.installed) | \(if .fixed == "" then "-" else .fixed end) |"
      ' "$scan"
      if [[ "$count" -gt 100 ]]; then
        printf '\nOnly the first 100 unique findings are shown.\n'
      fi
    } > "$body"

    number=$(jq -r '.number // empty' <<<"$issue")
    if [[ -z "$number" ]]; then
      gh issue create --repo "$repository" --title "$title" --body-file "$body"
    else
      state=$(jq -r .state <<<"$issue")
      if [[ "$state" == CLOSED ]]; then
        gh issue reopen "$number" --repo "$repository"
      fi
      gh issue edit "$number" --repo "$repository" --body-file "$body"
    fi
  else
    number=$(jq -r '.number // empty' <<<"$issue")
    state=$(jq -r '.state // empty' <<<"$issue")
    if [[ -n "$number" && "$state" == OPEN ]]; then
      gh issue close "$number" --repo "$repository" \
        --comment "The nightly verified-SBOM scan is clean. Closing automatically: $run_url"
    fi
  fi
done

current_titles=$(jq -c '[.images[] | "[CVE] \(.name):\(.version)"]' "$catalog")
retired_file=$work/retired.txt
jq -r --argjson current "$current_titles" '
  .[] | select(
    .author == "github-actions[bot]" and
    .state == "OPEN" and
    ((.body // "") | startswith("<!-- sbom-cve-monitor -->")) and
    (.title as $title | $current | index($title) | not)
  ) | .number
' <<<"$issues" > "$retired_file"
mapfile -t retired < "$retired_file"
for number in "${retired[@]}"; do
  gh issue close "$number" --repo "$repository" \
    --comment "This image version is no longer published. Closing automatically: $run_url"
done
