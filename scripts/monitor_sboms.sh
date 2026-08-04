#!/bin/bash
set -euo pipefail

payload=${1:?usage: monitor_sboms.sh PAYLOAD}
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
  [[ $(jq -r .state <<<"$issue") != closed ]] || gh issue reopen "$number" --repo "$repository"
  gh issue edit "$number" --repo "$repository" --body-file "$body"
fi
