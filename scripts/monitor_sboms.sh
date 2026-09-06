#!/bin/bash
set -euo pipefail

payload=${1:?usage: monitor_sboms.sh PAYLOAD [CHECKPOINT ACK_OUTPUT INDEX_DOCUMENT]}
checkpoint_envelope=${2:-}
ack_output=${3:-}
index_document=${4:-}
repository=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}
run_url=${RUN_URL:?RUN_URL is required}
server_url=${GITHUB_SERVER_URL:-https://github.com}
max_snapshot_age=${MAX_SNAPSHOT_AGE_SECONDS:-21600}
now=${NOW_EPOCH_SECONDS:-$(date -u +%s)}
root=$(cd "$(dirname "$0")/.." && pwd)
validator="$root/scripts/validate_squawk_reconciliation.jq"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

jq -e --arg mode wakeup -f "$validator" "$payload" >/dev/null
schema=$(jq -er .schema_version "$payload")
event_document=$payload
checkpoint_id=
revision=
payload_sha256=
source_installation=
source_repository=
if [[ $schema -eq 1 ]]; then
  event=finding
else
  [[ -n $checkpoint_envelope && -n $ack_output ]] || {
    printf 'schema-v2 reconciliation requires checkpoint and ack paths\n' >&2
    exit 1
  }
  jq -e --arg mode checkpoint -f "$validator" "$checkpoint_envelope" >/dev/null
  jq -e --slurpfile wakeup "$payload" '
    .checkpoint.logical_image_ref == $wakeup[0].logical_image_ref and
    .checkpoint.source.installation_id == $wakeup[0].source.installation_id and
    .checkpoint.source.repository_id == $wakeup[0].source.repository_id
  ' "$checkpoint_envelope" >/dev/null
  event_document="$work/checkpoint.json"
  jq -c .checkpoint "$checkpoint_envelope" > "$event_document"
  event=$(jq -er .kind "$event_document")
  checkpoint_id=$(jq -er .checkpoint_id "$event_document")
  revision=$(jq -er .revision "$event_document")
  payload_sha256=$(jq -er .payload_sha256 "$event_document")
  source_installation=$(jq -er .source.installation_id "$event_document")
  source_repository=$(jq -er .source.repository_id "$event_document")
  canonical_checkpoint=$(jq -cS 'del(.payload_sha256)' "$event_document")
  computed_payload_sha256=$(printf '%s' "$canonical_checkpoint" | sha256sum | cut -d' ' -f1)
  [[ $computed_payload_sha256 == "$payload_sha256" ]] || {
    printf 'Squawk checkpoint payload digest does not match canonical content\n' >&2
    exit 1
  }
  if [[ $event == inventory_snapshot ]]; then
    evaluated_at=$(jq -er .coverage.evaluated_at "$event_document")
    feed_checked_at=$(jq -er .coverage.advisory_feed_checked_at "$event_document")
    (( evaluated_at <= now + 300 && evaluated_at >= now - max_snapshot_age )) || {
      printf 'Squawk evaluation is stale or from the future\n' >&2
      exit 1
    }
    (( feed_checked_at <= now + 300 && feed_checked_at >= now - max_snapshot_age )) || {
      printf 'Squawk advisory feed check is stale or from the future\n' >&2
      exit 1
    }
    [[ -n $index_document && -f $index_document ]] || {
      printf 'inventory checkpoint requires the published OCI index document\n' >&2
      exit 1
    }
    logical_image=$(jq -er .logical_image_ref "$event_document")
    expected_index_digest=${logical_image##*@}
    actual_index_digest="sha256:$(sha256sum "$index_document" | cut -d' ' -f1)"
    [[ $actual_index_digest == "$expected_index_digest" ]] || {
      printf 'published OCI index digest does not match the logical image\n' >&2
      exit 1
    }
    jq -e --slurpfile checkpoint "$event_document" --arg repository "${logical_image%@*}" '
      .schemaVersion == 2 and (.manifests | type == "array") and
      ([.manifests[] |
        select(.platform.os == "linux" and (.platform.architecture == "amd64" or .platform.architecture == "arm64")) |
        {platform:(.platform.os + "/" + .platform.architecture),image_ref:($repository + "@" + .digest)}
      ] | sort_by(.platform)) ==
      ([$checkpoint[0].platforms[] | {platform,image_ref}] | sort_by(.platform))
    ' "$index_document" >/dev/null || {
      printf 'checkpoint platforms do not match the published OCI index\n' >&2
      exit 1
    }
  fi
fi

write_ack() {
  [[ $schema -eq 2 ]] || return
  jq -n --arg checkpoint_id "$checkpoint_id" --argjson revision "$revision" \
    --arg payload_sha256 "$payload_sha256" \
    '{checkpoint_id:$checkpoint_id,revision:$revision,payload_sha256:$payload_sha256}' > "$ack_output"
}

delivery=$(jq -er .delivery_id "$payload")
image=$(jq -er .logical_image_ref "$payload")
image_marker="<!-- squawk-image:${image} -->"
legacy_image_line="- Logical image: ${image}"
image_name=${image%%@sha256:*}
digest=${image##*@sha256:}
short_digest=${digest:0:12}
title="[CVE] ${image_name#ghcr.io/} image vulnerabilities (${short_digest})"
body="$work/issue-body.md"
comment="$work/comment.md"
mkdir "$work/comments"

load_issues() {
  gh api --paginate --slurp "repos/${repository}/issues?state=all&labels=squawk&per_page=100"
}

load_comments() {
  local cached="$work/comments/$1.json"
  if [[ ! -f $cached ]]; then
    gh api --paginate --slurp "repos/${repository}/issues/$1/comments?per_page=100" | jq -c '[.[][]]' > "$cached"
  fi
  cat "$cached"
}

select_candidates() {
  jq -c --arg marker "$image_marker" --arg legacy "$legacy_image_line" '
    [.[][] |
      select(has("pull_request") | not) |
      select(.user.login == "github-actions[bot]") |
      select(((.body // "") | contains($marker)) or (((.body // "") | split("\n")) | index($legacy) != null))
    ] | unique_by(.number) | sort_by(.number)
  '
}

write_active_body() {
  cat > "$body" <<EOF
$image_marker
Squawk reported one or more vulnerabilities for this immutable image.

- Logical image: $image
- Latest workflow: $run_url

Each finding is recorded below as a separate comment. Rebuilding this image should address the complete set in one pull request.
EOF
}

write_finding_comment() {
  jq -r --arg run "$run_url" '
    "<!-- squawk-delivery:\(.delivery_id) -->\n### `\(.vuln_id)` in `\(.package_name)@\(.version)`\n\n- Ecosystem: \(.ecosystem)\n- Severity: \(.severity // "unknown")\n- Workflow: \($run)\n\n| Platform | Digest |\n|---|---|\n" +
    ([.platforms[] | "| \(.platform) | `\(.image_ref)` |"] | join("\n"))
  ' > "$comment"
}

issues=$(load_issues)
candidates=$(select_candidates <<<"$issues")
issue=$(jq -c '.[0] // null' <<<"$candidates")
number=$(jq -r '.number // empty' <<<"$issue")
needs_issue=true
if [[ $event == inventory_snapshot && $(jq -r '.findings | length' "$event_document") -eq 0 ]] || [[ $event == retirement ]]; then
  needs_issue=false
fi
if [[ -z $number && $needs_issue == true ]]; then
  write_active_body
  gh label create squawk --repo "$repository" --color 5319E7 --description "Squawk vulnerability alert" --force
  created=$(gh issue create --repo "$repository" --title "$title" --body-file "$body" --label squawk)
  number=${created##*/}
  [[ $number =~ ^[0-9]+$ ]] || { printf 'could not determine created Squawk issue number\n' >&2; exit 1; }
  issue=$(jq -cn --argjson number "$number" --arg marker "$image_marker" \
    '{number: $number, state: "open", body: $marker, user: {login: "github-actions[bot]"}}')
fi
if [[ -z $number ]]; then
  write_ack
  exit 0
fi

# Re-read after a possible create. Distinct deliveries retain independent workflow
# concurrency, then converge any create race on the oldest bot-authored image issue.
issues=$(load_issues)
candidates=$(select_candidates <<<"$issues")
candidates=$(jq -cn --argjson direct "$candidates" \
  --argjson all "$(jq -c '[.[][]]' <<<"$issues")" --argjson seed "$issue" '
  (($direct + [$seed]) | unique_by(.number) | sort_by(.number)) as $seeded |
  ($seeded | map(.number | tostring)) as $targets |
  ($seeded + [$all[] |
    select(has("pull_request") | not) |
    select(.user.login == "github-actions[bot]") |
    select((.body // "") as $body | any($targets[]; . as $target | $body | contains("<!-- squawk-consolidated-into:" + $target + " -->")))
  ]) | unique_by(.number) | sort_by(.number)
')
issue=$(jq -c '.[0]' <<<"$candidates")
number=$(jq -r .number <<<"$issue")
canonical_comments=$(load_comments "$number")
ordering_comments=$canonical_comments
if [[ $schema -eq 2 ]]; then
  while IFS= read -r ordering_issue; do
    ordering_number=$(jq -r .number <<<"$ordering_issue")
    [[ $ordering_number != "$number" ]] || continue
    ordering_comments=$(jq -c --argjson more "$(load_comments "$ordering_number")" '. + $more' \
      <<<"$ordering_comments")
  done < <(jq -c '.[]' <<<"$candidates")
fi
if [[ $schema -eq 2 ]]; then
  applied_state=$(jq -c --arg installation "$source_installation" --arg repository "$source_repository" '
    [.[] |
      select(.user.login == "github-actions[bot]") |
      ((.body // "") | capture("<!-- squawk-applied:(?<installation>[0-9]+):(?<repository>[0-9]+):(?<revision>[0-9]+):(?<sha>[a-f0-9]{64}) -->")?) |
      select(.installation == $installation and .repository == $repository) |
      {revision:(.revision | tonumber),sha}
    ] as $markers |
    {conflict:([$markers | group_by(.revision)[] | select([.[].sha] | unique | length > 1)] | length > 0),
     latest:($markers | sort_by(.revision) | last // null)}
  ' <<<"$ordering_comments")
  [[ $(jq -r .conflict <<<"$applied_state") == false ]] || {
    printf 'conflicting applied checkpoint markers exist\n' >&2
    exit 1
  }
  applied=$(jq -c .latest <<<"$applied_state")
  if [[ $applied != null ]]; then
    applied_revision=$(jq -r .revision <<<"$applied")
    applied_sha=$(jq -r .sha <<<"$applied")
    if (( applied_revision > revision )); then
      printf 'checkpoint revision %s is older than applied revision %s\n' "$revision" "$applied_revision" >&2
      exit 1
    elif (( applied_revision == revision )); then
      [[ $applied_sha == "$payload_sha256" ]] || {
        printf 'checkpoint revision %s conflicts with its applied digest\n' "$revision" >&2
        exit 1
      }
      write_ack
      exit 0
    fi
  fi
fi

post_canonical_once() {
  local marker=$1 file=$2
  if jq -e --arg marker "$marker" \
    'any(.[]; .user.login == "github-actions[bot]" and ((.body // "") | contains($marker)))' \
    <<<"$canonical_comments" >/dev/null; then
    return
  fi
  gh issue comment "$number" --repo "$repository" --body-file "$file"
  canonical_comments=$(jq -c --arg body "$(cat "$file")" \
    '. + [{body: $body, user: {login: "github-actions[bot]"}}]' <<<"$canonical_comments")
}

preserve_body() {
  local source=$1 source_body=$2 marker="<!-- squawk-migrated-body:${1} -->"
  if [[ $source_body != *'<!-- squawk-delivery:'* ]]; then
    return 0
  fi
  {
    printf '%s\nPreserved from the original body of #%s before consolidation:\n\n' "$marker" "$source"
    printf '%s\n' "$source_body"
  } > "$comment"
  post_canonical_once "$marker" "$comment"
}

copy_finding_comments() {
  local source=$1 source_comments=$2 row marker source_body
  while IFS= read -r row; do
    marker=$(jq -r '.body | match("<!-- squawk-delivery:[a-f0-9]{64} -->").string' <<<"$row")
    source_body=$(jq -r .body <<<"$row")
    {
      printf '<!-- squawk-migrated-comment:%s:%s -->\nPreserved from #%s' \
        "$source" "$(jq -r '.id // 0' <<<"$row")" "$source"
      if [[ $(jq -r '.html_url // ""' <<<"$row") != "" ]]; then
        printf ' ([source](%s))' "$(jq -r .html_url <<<"$row")"
      fi
      printf ':\n\n%s\n' "$source_body"
    } > "$comment"
    post_canonical_once "$marker" "$comment"
  done < <(jq -c '.[] | select(.user.login == "github-actions[bot]") | select((.body // "") | test("<!-- squawk-delivery:[a-f0-9]{64} -->"))' <<<"$source_comments")
}

preserve_body "$number" "$(jq -r '.body // ""' <<<"$issue")"
while IFS= read -r duplicate; do
  duplicate_number=$(jq -r .number <<<"$duplicate")
  [[ $duplicate_number != "$number" ]] || continue
  duplicate_comments=$(load_comments "$duplicate_number")
  preserve_body "$duplicate_number" "$(jq -r '.body // ""' <<<"$duplicate")"
  copy_finding_comments "$duplicate_number" "$duplicate_comments"

  source_marker="<!-- squawk-source-issue:${duplicate_number} -->"
  {
    printf '%s\nRelated Squawk issue #%s was consolidated here. ' "$source_marker" "$duplicate_number"
    printf 'Its original body and discussion remain at %s/%s/issues/%s.\n' \
      "$server_url" "$repository" "$duplicate_number"
  } > "$comment"
  post_canonical_once "$source_marker" "$comment"

  tombstone_marker="<!-- squawk-consolidated-into:${number} -->"
  if ! jq -e --arg marker "$tombstone_marker" \
    'any(.[]; .user.login == "github-actions[bot]" and ((.body // "") | contains($marker)))' \
    <<<"$duplicate_comments" >/dev/null; then
    printf '%s\nConsolidated into #%s; original evidence and discussion remain above.\n' \
      "$tombstone_marker" "$number" > "$comment"
    gh issue comment "$duplicate_number" --repo "$repository" --body-file "$comment"
  fi
  [[ $(jq -r .state <<<"$duplicate") == closed ]] || \
    gh issue close "$duplicate_number" --repo "$repository" --reason "not planned"
done < <(jq -c '.[]' <<<"$candidates")

if [[ $event == finding ]]; then
  [[ $(jq -r .state <<<"$issue") != closed ]] || gh issue reopen "$number" --repo "$repository"
  write_active_body
  gh issue edit "$number" --repo "$repository" --title "$title" --body-file "$body"
  write_finding_comment < "$payload"
  post_canonical_once "<!-- squawk-delivery:${delivery} -->" "$comment"
elif [[ $event == inventory_snapshot ]]; then
  active=$(jq -r '.findings | length' "$event_document")
  if (( active > 0 )); then
    [[ $(jq -r .state <<<"$issue") != closed ]] || gh issue reopen "$number" --repo "$repository"
    write_active_body
    gh issue edit "$number" --repo "$repository" --title "$title" --body-file "$body"
    while IFS= read -r finding; do
      write_finding_comment <<<"$finding"
      post_canonical_once "<!-- squawk-delivery:$(jq -r .delivery_id <<<"$finding") -->" "$comment"
    done < <(jq -c '. as $snapshot | .findings[] as $finding |
      $finding + {platforms: [$finding.platforms[] as $platform | $snapshot.platforms[] |
        select(.platform == $platform) | {platform, image_ref}]}' "$event_document")
  else
    cat > "$body" <<EOF
$image_marker
Squawk reports no current vulnerabilities for this immutable image after a complete two-platform evaluation.

- Logical image: $image
- Evaluation completed: $(date -u -d "@$evaluated_at" +%Y-%m-%dT%H:%M:%SZ)
- Advisory feed checked: $(date -u -d "@$feed_checked_at" +%Y-%m-%dT%H:%M:%SZ)
- Workflow: $run_url

This security-fixed state is based on authenticated, complete coverage for linux/amd64 and linux/arm64.
EOF
    gh issue edit "$number" --repo "$repository" --title "$title" --body-file "$body"
  fi
  checkpoint_marker="<!-- squawk-checkpoint:${checkpoint_id} -->"
  {
    printf '%s\nComplete Squawk checkpoint revision %s at %s with %s current finding(s).\n' \
      "$checkpoint_marker" "$revision" "$(date -u -d "@$evaluated_at" +%Y-%m-%dT%H:%M:%SZ)" "$active"
    printf 'Advisory feed checked at %s. Platforms: linux/amd64, linux/arm64.\n' \
      "$(date -u -d "@$feed_checked_at" +%Y-%m-%dT%H:%M:%SZ)"
  } > "$comment"
  post_canonical_once "$checkpoint_marker" "$comment"
  (( active > 0 )) || { [[ $(jq -r .state <<<"$issue") == closed ]] || gh issue close "$number" --repo "$repository" --reason "completed"; }
else
  replacement=$(jq -er .replacement.logical_image_ref "$event_document")
  retired_at=$(jq -er .retired_at "$event_document")
  published_at=$(jq -er .replacement.published_at "$event_document")
  source_event=$(jq -er .authoritative_source_event_id "$event_document")
  publisher_run=$(jq -er .replacement.run_url "$event_document")
  cat > "$body" <<EOF
$image_marker
This immutable image was retired from Squawk monitoring after authoritative publication of a replacement.

- Historical image: $image
- Replacement image: $replacement
- Replacement published: $(date -u -d "@$published_at" +%Y-%m-%dT%H:%M:%SZ)
- Retired at: $(date -u -d "@$retired_at" +%Y-%m-%dT%H:%M:%SZ)
- Replacement publication: $publisher_run

Historical retirement is not evidence that vulnerabilities in this digest were fixed.
EOF
  gh issue edit "$number" --repo "$repository" --title "$title" --body-file "$body"
  checkpoint_marker="<!-- squawk-checkpoint:${checkpoint_id} -->"
  printf "%s\nRetired in favor of \`%s\` from authoritative source event \`%s\`. This is lifecycle retirement, not a security-fixed result.\n" \
    "$checkpoint_marker" "$replacement" "$source_event" > "$comment"
  post_canonical_once "$checkpoint_marker" "$comment"
  [[ $(jq -r .state <<<"$issue") == closed ]] || gh issue close "$number" --repo "$repository" --reason "not planned"
fi

if [[ $schema -eq 2 ]]; then
  applied_marker="<!-- squawk-applied:${source_installation}:${source_repository}:${revision}:${payload_sha256} -->"
  printf "%s\nApplied authenticated Squawk checkpoint \`%s\` revision %s.\n" \
    "$applied_marker" "$checkpoint_id" "$revision" > "$comment"
  post_canonical_once "$applied_marker" "$comment"
  write_ack
fi
