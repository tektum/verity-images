#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/bodies"
delivery=$(printf delivery | sha256sum | cut -d' ' -f1)
image="ghcr.io/tektum/demo@sha256:$(printf index | sha256sum | cut -d' ' -f1)"
cat > "$work/payload.json" <<EOF
{
  "schema_version": 1,
  "delivery_id": "$delivery",
  "logical_image_ref": "$image",
  "package_name": "openssl",
  "ecosystem": "Alpine",
  "version": "3.1.2",
  "vuln_id": "CVE-TEST",
  "severity": "high",
  "platforms": [
    {"platform":"linux/amd64","image_ref":"ghcr.io/tektum/demo@sha256:$(printf amd64 | sha256sum | cut -d' ' -f1)"},
    {"platform":"linux/arm64","image_ref":"ghcr.io/tektum/demo@sha256:$(printf arm64 | sha256sum | cut -d' ' -f1)"}
  ]
}
EOF

cat > "$work/bin/gh" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%q ' "$@" >> "$GH_LOG"
printf '\n' >> "$GH_LOG"
if [[ "$1" == api ]]; then
  if [[ "$*" == *'/comments?'* ]]; then
    for argument in "$@"; do
      [[ $argument == repos/owner/repo/issues/*/comments\?* ]] || continue
      issue_number=${argument#repos/owner/repo/issues/}
      issue_number=${issue_number%%/*}
    done
    variable="COMMENTS_${issue_number}"
    jq -cn --argjson comments "${!variable:-${COMMENTS:-[]}}" '[$comments]'
  elif [[ -n ${ISSUES_FILE:-} && -s $ISSUES_FILE ]]; then
    IFS= read -r response < "$ISSUES_FILE"
    sed -i '1d' "$ISSUES_FILE"
    printf '%s\n' "$response"
  else
    printf '%s\n' "${ISSUES:-[]}"
  fi
elif [[ "$1 $2" == "issue create" || "$1 $2" == "issue edit" || "$1 $2" == "issue comment" ]]; then
  for ((index=1; index <= $#; index++)); do
    if [[ ${!index} == --body-file ]]; then
      body_index=$((index + 1))
      cp "${!body_index}" "$GH_BODY_DIR/${1}-${2}.md"
      {
        printf '%s %s %s\n' "$1" "$2" "${3:-}"
        cat "${!body_index}"
        printf '%s\n' '-- body end --'
      } >> "$GH_BODY_LOG"
    fi
  done
  [[ "$1 $2" != "issue create" ]] || printf '%s\n' 'https://github.com/owner/repo/issues/42'
fi
EOF
chmod +x "$work/bin/gh"
export GH_BODY_DIR=$work/bodies
export GH_LOG=$work/gh.log
export GH_BODY_LOG=$work/body.log
export GITHUB_REPOSITORY=owner/repo
export RUN_URL=https://example.test/run
export ISSUES='[]'
export COMMENTS='[]'
image_marker="<!-- squawk-image:$image -->"

PATH="$work/bin:$PATH" "$root/scripts/monitor_sboms.sh" "$work/payload.json"
grep -Fq 'api --paginate --slurp repos/owner/repo/issues\?state=all\&labels=squawk\&per_page=100' "$GH_LOG"
grep -Fq 'label create squawk --repo owner/repo --color 5319E7' "$GH_LOG"
grep -Fq 'issue create --repo owner/repo --title \[CVE\]\ tektum/demo\ image\ vulnerabilities' "$GH_LOG"
grep -Fq 'issue comment 42 --repo owner/repo' "$GH_LOG"
grep -Fq -- '--label squawk' "$GH_LOG"
grep -Fq "$image_marker" "$work/bodies/issue-create.md"
grep -Fq "<!-- squawk-delivery:$delivery -->" "$work/bodies/issue-comment.md"
grep -Fq "### \`CVE-TEST\` in \`openssl@3.1.2\`" "$work/bodies/issue-comment.md"
grep -Fq '| linux/amd64 |' "$work/bodies/issue-comment.md"

# A user-authored marker cannot capture Squawk's reconciliation target.
: > "$GH_LOG"
export ISSUES="[[{\"number\":7,\"state\":\"open\",\"body\":\"$image_marker\",\"user\":{\"login\":\"attacker\"}}]]"
export COMMENTS='[]'
PATH="$work/bin:$PATH" "$root/scripts/monitor_sboms.sh" "$work/payload.json"
grep -Fq 'issue create --repo owner/repo' "$GH_LOG"
grep -Fq 'issue edit 42 --repo owner/repo' "$GH_LOG"
if grep -Fq 'issue edit 7' "$GH_LOG"; then
  printf 'user-authored image marker captured reconciliation\n' >&2
  exit 1
fi

# A repeated delivery updates the image issue but does not add a duplicate comment.
: > "$GH_LOG"
rm -f "$work/bodies/issue-comment.md"
export ISSUES="[[{\"number\":8,\"state\":\"closed\",\"body\":\"$image_marker\",\"user\":{\"login\":\"github-actions[bot]\"}}]]"
export COMMENTS="[{\"body\":\"<!-- squawk-delivery:$delivery -->\",\"user\":{\"login\":\"github-actions[bot]\"}}]"
PATH="$work/bin:$PATH" "$root/scripts/monitor_sboms.sh" "$work/payload.json"
grep -Fq 'issue reopen 8 --repo owner/repo' "$GH_LOG"
grep -Fq 'issue edit 8 --repo owner/repo --title \[CVE\]\ tektum/demo\ image\ vulnerabilities' "$GH_LOG"
if grep -Fq 'issue comment' "$GH_LOG"; then
  printf 'repeated delivery created a duplicate comment\n' >&2
  exit 1
fi

# A second finding for the same image becomes another comment on the same issue.
second_delivery=$(printf second-delivery | sha256sum | cut -d' ' -f1)
jq --arg delivery "$second_delivery" '.delivery_id = $delivery | .package_name = "libssl3" | .version = "3.1.3" | .vuln_id = "CVE-SECOND"' \
  "$work/payload.json" > "$work/second.json"
: > "$GH_LOG"
export ISSUES="[[{\"number\":8,\"state\":\"open\",\"body\":\"$image_marker\",\"user\":{\"login\":\"github-actions[bot]\"}}]]"
PATH="$work/bin:$PATH" "$root/scripts/monitor_sboms.sh" "$work/second.json"
grep -Fq 'issue edit 8 --repo owner/repo' "$GH_LOG"
grep -Fq 'issue comment 8 --repo owner/repo' "$GH_LOG"
if grep -Fq 'issue create' "$GH_LOG"; then
  printf 'second image finding created another issue\n' >&2
  exit 1
fi
# Concurrent creates converge on the oldest issue. Legacy evidence is copied to
# the canonical thread, discussion remains linked, and the duplicate body is never rewritten.
: > "$GH_LOG"
: > "$GH_BODY_LOG"
legacy_delivery=$(printf legacy-delivery | sha256sum | cut -d' ' -f1)
legacy_body=$(printf '%s\n' \
  "<!-- squawk-delivery:$legacy_delivery -->" \
  "Squawk reported **CVE-LEGACY** for \`legacy@1\` in \`Alpine:v3.23\`." \
  '' \
  "- Logical image: $image")
export COMMENTS='[]'
export COMMENTS_8='[]'
export COMMENTS_42="[{\"id\":420,\"html_url\":\"https://example.test/issues/42#issuecomment-420\",\"body\":\"<!-- squawk-delivery:$legacy_delivery -->\\nlegacy comment evidence\",\"user\":{\"login\":\"github-actions[bot]\"}},{\"id\":421,\"html_url\":\"https://example.test/issues/42#issuecomment-421\",\"body\":\"maintainer discussion\",\"user\":{\"login\":\"maintainer\"}}]"
export ISSUES_FILE="$work/issues-sequence"
printf '%s\n' '[]' > "$ISSUES_FILE"
jq -cn --arg marker "$image_marker" --arg legacy "$legacy_body" \
  '[[{number:8,state:"open",body:$marker,user:{login:"github-actions[bot]"}},
      {number:42,state:"open",body:$legacy,user:{login:"github-actions[bot]"}}]]' >> "$ISSUES_FILE"
PATH="$work/bin:$PATH" "$root/scripts/monitor_sboms.sh" "$work/payload.json"
unset ISSUES_FILE
grep -Fq 'issue create --repo owner/repo' "$GH_LOG"
grep -Fq 'issue edit 8 --repo owner/repo' "$GH_LOG"
grep -Fq 'issue close 42 --repo owner/repo --reason not\ planned' "$GH_LOG"
if grep -Fq 'issue edit 42' "$GH_LOG"; then
  printf 'duplicate evidence body was rewritten\n' >&2
  exit 1
fi
grep -Fq "<!-- squawk-migrated-body:42 -->" "$GH_BODY_LOG"
grep -Fq "<!-- squawk-delivery:$legacy_delivery -->" "$GH_BODY_LOG"
grep -Fq '<!-- squawk-source-issue:42 -->' "$GH_BODY_LOG"
grep -Fq 'original body and discussion remain' "$GH_BODY_LOG"
grep -Fq '<!-- squawk-consolidated-into:8 -->' "$GH_BODY_LOG"

# A replay sees the migration markers and adds no duplicate evidence or tombstones.
: > "$GH_LOG"
: > "$GH_BODY_LOG"
ISSUES=$(jq -cn --arg marker "$image_marker" --arg legacy "$legacy_body" \
  '[[{number:8,state:"open",body:$marker,user:{login:"github-actions[bot]"}},
      {number:42,state:"closed",body:$legacy,user:{login:"github-actions[bot]"}}]]')
export ISSUES
export COMMENTS_8="[{\"body\":\"<!-- squawk-migrated-body:42 --> <!-- squawk-delivery:$legacy_delivery -->\",\"user\":{\"login\":\"github-actions[bot]\"}},{\"body\":\"<!-- squawk-source-issue:42 -->\",\"user\":{\"login\":\"github-actions[bot]\"}},{\"body\":\"<!-- squawk-delivery:$delivery -->\",\"user\":{\"login\":\"github-actions[bot]\"}}]"
export COMMENTS_42='[{"body":"<!-- squawk-consolidated-into:8 -->","user":{"login":"github-actions[bot]"}}]'
PATH="$work/bin:$PATH" "$root/scripts/monitor_sboms.sh" "$work/payload.json"
if grep -Fq 'issue comment' "$GH_LOG"; then
  printf 'migration replay duplicated a comment\n' >&2
  exit 1
fi

# When the oldest issue itself uses the legacy per-delivery body, its finding is
# preserved as a canonical comment before the body is migrated to image scope.
: > "$GH_LOG"
: > "$GH_BODY_LOG"
ISSUES=$(jq -cn --arg legacy "$legacy_body" \
  '[[{number:5,state:"open",body:$legacy,user:{login:"github-actions[bot]"}}]]')
export ISSUES
unset COMMENTS_8 COMMENTS_42
export COMMENTS_5='[]'
PATH="$work/bin:$PATH" "$root/scripts/monitor_sboms.sh" "$work/payload.json"
grep -Fq '<!-- squawk-migrated-body:5 -->' "$GH_BODY_LOG"
preserve_line=$(grep -nF 'issue comment 5' "$GH_LOG" | cut -d: -f1 | sed -n '1p')
edit_line=$(grep -nF 'issue edit 5' "$GH_LOG" | cut -d: -f1)
(( preserve_line < edit_line )) || { printf 'legacy body was rewritten before preservation\n' >&2; exit 1; }
unset COMMENTS_5

# Squawk persists advisory severity as a label, CVSS v2/v3/v4 vector, or null.
# Accepted strings are preserved; null renders as unknown in the finding comment.
export ISSUES="[[{\"number\":8,\"state\":\"open\",\"body\":\"$image_marker\",\"user\":{\"login\":\"github-actions[bot]\"}}]]"
export COMMENTS='[]'
for severity in \
  'CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:N/A:H' \
  'CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:N/VC:N/VI:N/VA:H/SC:N/SI:N/SA:N/U:Amber' \
  'AV:N/AC:L/Au:N/C:P/I:P/A:P'; do
  rm -f "$work/bodies/issue-comment.md"
  jq --arg severity "$severity" '.severity = $severity' \
    "$work/payload.json" > "$work/cvss.json"
  PATH="$work/bin:$PATH" "$root/scripts/monitor_sboms.sh" "$work/cvss.json"
  grep -Fq -- "- Severity: $severity" "$work/bodies/issue-comment.md"
done

rm -f "$work/bodies/issue-comment.md"
jq '.severity = null' "$work/payload.json" > "$work/null-severity.json"
PATH="$work/bin:$PATH" "$root/scripts/monitor_sboms.sh" "$work/null-severity.json"
grep -Fq -- '- Severity: unknown' "$work/bodies/issue-comment.md"

# V1 finding deliveries are evidence-only and legitimately carry one platform or
# repeated platform labels. Preserve every valid row; complete coverage is v2-only.
single_delivery=$(printf single-platform | sha256sum | cut -d' ' -f1)
jq --arg delivery "$single_delivery" '.delivery_id = $delivery | .platforms = [.platforms[0]]' \
  "$work/payload.json" > "$work/single-platform.json"
PATH="$work/bin:$PATH" "$root/scripts/monitor_sboms.sh" "$work/single-platform.json"
[[ $(grep -Fc '| linux/amd64 |' "$work/bodies/issue-comment.md") -eq 1 ]]

repeated_delivery=$(printf repeated-platform | sha256sum | cut -d' ' -f1)
jq --arg delivery "$repeated_delivery" \
  '.delivery_id = $delivery | .platforms = [.platforms[0], .platforms[0]]' \
  "$work/payload.json" > "$work/repeated-platform.json"
PATH="$work/bin:$PATH" "$root/scripts/monitor_sboms.sh" "$work/repeated-platform.json"
[[ $(grep -Fc '| linux/amd64 |' "$work/bodies/issue-comment.md") -eq 2 ]]

: > "$GH_LOG"
jq '.platforms[0].image_ref = "ghcr.io/tektum/demo:latest"' \
  "$work/payload.json" > "$work/invalid.json"
if PATH="$work/bin:$PATH" "$root/scripts/monitor_sboms.sh" "$work/invalid.json"; then
  printf 'mutable image reference was accepted\n' >&2
  exit 1
fi
[[ ! -s "$GH_LOG" ]] || { printf 'mutable image reference called GitHub\n' >&2; exit 1; }

for invalid in marker severity severity-type severity-vector severity-long platform-empty platform-name platform-repository; do
  case $invalid in
    marker) jq --arg marker $'openssl\n<!-- squawk-delivery:bad -->' '.package_name = $marker' "$work/payload.json" ;;
    severity) jq '.severity = "urgent"' "$work/payload.json" ;;
    severity-type) jq '.severity = false' "$work/payload.json" ;;
    severity-vector) jq '.severity = "foo:bar/baz:qux"' "$work/payload.json" ;;
    severity-long) jq --arg severity "CVSS:3.1$(printf '/AV:N%.0s' {1..70})" '.severity = $severity' "$work/payload.json" ;;
    platform-empty) jq '.platforms = []' "$work/payload.json" ;;
    platform-name) jq '.platforms[0].platform = "windows/amd64"' "$work/payload.json" ;;
    platform-repository) jq '.platforms[1].image_ref |= sub("tektum/demo"; "tektum/other")' "$work/payload.json" ;;
  esac > "$work/invalid.json"
  : > "$GH_LOG"
  if PATH="$work/bin:$PATH" "$root/scripts/monitor_sboms.sh" "$work/invalid.json"; then
    printf 'invalid %s payload was accepted\n' "$invalid" >&2
    exit 1
  fi
  [[ ! -s "$GH_LOG" ]] || { printf 'invalid %s payload called GitHub\n' "$invalid" >&2; exit 1; }
done

checkpoint_hash() {
  local file canonical
  file=$1
  canonical=$(jq -cS '.checkpoint | del(.payload_sha256)' "$file")
  printf '%s' "$canonical" | sha256sum | cut -d' ' -f1
}

rehash_checkpoint() {
  local file digest temporary
  file=$1
  digest=$(checkpoint_hash "$file")
  temporary="${file}.tmp"
  jq --arg digest "$digest" '.checkpoint.payload_sha256 = $digest' "$file" > "$temporary"
  mv "$temporary" "$file"
}

canonical_vector=$(jq -cS 'del(.payload_sha256)' <<'EOF'
{"revision":1,"source":{"repository_id":"9","installation_id":"1"},"kind":"inventory_snapshot","findings":[],"checkpoint_id":"a"}
EOF
)
[[ $(printf '%s' "$canonical_vector" | sha256sum | cut -d' ' -f1) == \
  ae7a64643c3dbd8b8058b953df74787815593df62ded43f682a9280527e61c47 ]]

# Schema v2 accepts only authenticated-ready checkpoint material fetched by the
# workflow. A complete fresh empty snapshot can close an existing canonical issue.
export NOW_EPOCH_SECONDS=2000000000
wakeup_delivery=$(printf wakeup | sha256sum | cut -d' ' -f1)
checkpoint_id=$(printf checkpoint-clean | sha256sum | cut -d' ' -f1)
checkpoint_sha=$(printf checkpoint-clean-payload | sha256sum | cut -d' ' -f1)
feed_checkpoint=$(printf feed-checkpoint | sha256sum | cut -d' ' -f1)
amd64_digest="sha256:$(printf amd64 | sha256sum | cut -d' ' -f1)"
arm64_digest="sha256:$(printf arm64 | sha256sum | cut -d' ' -f1)"
index_raw=$(jq -cn --arg amd64 "$amd64_digest" --arg arm64 "$arm64_digest" '
  {schemaVersion:2,manifests:[
    {digest:$amd64,platform:{os:"linux",architecture:"amd64"}},
    {digest:$arm64,platform:{os:"linux",architecture:"arm64"}}]}')
printf '%s' "$index_raw" > "$work/oci-index.json"
v2_image="ghcr.io/tektum/demo@sha256:$(printf '%s' "$index_raw" | sha256sum | cut -d' ' -f1)"
v2_image_marker="<!-- squawk-image:$v2_image -->"
jq -n --arg delivery "$wakeup_delivery" --arg image "$v2_image" \
  '{schema_version:2,event:"reconcile",delivery_id:$delivery,logical_image_ref:$image,
    source:{installation_id:"11",repository_id:"22"}}' > "$work/wakeup.json"
jq -n --arg checkpoint "$checkpoint_id" --arg sha "$checkpoint_sha" --arg image "$v2_image" \
  --arg feed "$feed_checkpoint" --arg amd64 "ghcr.io/tektum/demo@$amd64_digest" \
  --arg arm64 "ghcr.io/tektum/demo@$arm64_digest" '
  {schema_version:2,state:"ready",checkpoint:{
    checkpoint_id:$checkpoint,revision:1,payload_sha256:$sha,logical_image_ref:$image,
    source:{installation_id:"11",repository_id:"22",ingestion_delivery_id:"ingestion-1"},
    kind:"inventory_snapshot",
    coverage:{status:"complete",evaluated_at:2000000000,advisory_feed_checked_at:1999999940,
      feed_checkpoint_ids:[$feed],unsupported_components:[]},
    platforms:[
      {platform:"linux/amd64",image_ref:$amd64,sbom_sha256:("a" * 64),indexed_at:100,status:"complete"},
      {platform:"linux/arm64",image_ref:$arm64,sbom_sha256:("b" * 64),indexed_at:100,status:"complete"}],
    findings:[]}}' > "$work/checkpoint.json"
rehash_checkpoint "$work/checkpoint.json"
checkpoint_sha=$(jq -r .checkpoint.payload_sha256 "$work/checkpoint.json")
: > "$GH_LOG"
: > "$GH_BODY_LOG"
export ISSUES="[[{\"number\":8,\"state\":\"open\",\"body\":\"$v2_image_marker\",\"user\":{\"login\":\"github-actions[bot]\"}}]]"
export COMMENTS='[]'
unset COMMENTS_8 COMMENTS_42
PATH="$work/bin:$PATH" "$root/scripts/monitor_sboms.sh" \
  "$work/wakeup.json" "$work/checkpoint.json" "$work/ack.json" "$work/oci-index.json"
grep -Fq 'issue close 8 --repo owner/repo --reason completed' "$GH_LOG"
grep -Fq 'authenticated, complete coverage for linux/amd64 and linux/arm64' "$work/bodies/issue-edit.md"
grep -Fq "<!-- squawk-applied:11:22:1:$checkpoint_sha -->" "$GH_BODY_LOG"
jq -e --arg id "$checkpoint_id" --arg sha "$checkpoint_sha" \
  '. == {checkpoint_id:$id,revision:1,payload_sha256:$sha}' "$work/ack.json" >/dev/null

: > "$GH_LOG"
rm -f "$work/missing-index-ack.json"
if PATH="$work/bin:$PATH" "$root/scripts/monitor_sboms.sh" \
  "$work/wakeup.json" "$work/checkpoint.json" "$work/missing-index-ack.json"; then
  printf 'checkpoint without published index evidence was accepted\n' >&2
  exit 1
fi
[[ ! -s "$GH_LOG" ]]
[[ ! -e "$work/missing-index-ack.json" ]]

# Missing, incomplete, unsupported, stale, or identity-mismatched coverage fails
# before any GitHub operation and cannot close the issue.
for invalid in digest-mismatch missing incomplete unsupported duplicate-feed stale-evaluation stale-feed source-mismatch platform-repository platform-index; do
  case $invalid in
    digest-mismatch) jq '.checkpoint.revision = 2' "$work/checkpoint.json" ;;
    missing) jq '.checkpoint.platforms = [.checkpoint.platforms[0]]' "$work/checkpoint.json" ;;
    incomplete) jq '.checkpoint.platforms[1].status = "pending"' "$work/checkpoint.json" ;;
    unsupported) jq '.checkpoint.coverage.unsupported_components = ["pkg:deb/ubuntu/test@1"]' "$work/checkpoint.json" ;;
    duplicate-feed) jq '.checkpoint.coverage.feed_checkpoint_ids += .checkpoint.coverage.feed_checkpoint_ids' "$work/checkpoint.json" ;;
    stale-evaluation) jq '.checkpoint.coverage.evaluated_at = 1999978399 | .checkpoint.coverage.advisory_feed_checked_at = 1999978300' "$work/checkpoint.json" ;;
    stale-feed) jq '.checkpoint.coverage.advisory_feed_checked_at = 1999978399' "$work/checkpoint.json" ;;
    source-mismatch) jq '.checkpoint.source.repository_id = "23"' "$work/checkpoint.json" ;;
    platform-repository) jq '.checkpoint.platforms[1].image_ref |= sub("tektum/demo"; "tektum/other")' "$work/checkpoint.json" ;;
    platform-index) jq '.checkpoint.platforms[1].image_ref = ("ghcr.io/tektum/demo@sha256:" + ("c" * 64))' "$work/checkpoint.json" ;;
  esac > "$work/invalid-checkpoint.json"
  [[ $invalid == digest-mismatch ]] || rehash_checkpoint "$work/invalid-checkpoint.json"
  : > "$GH_LOG"
  rm -f "$work/invalid-ack.json"
  if PATH="$work/bin:$PATH" "$root/scripts/monitor_sboms.sh" \
    "$work/wakeup.json" "$work/invalid-checkpoint.json" "$work/invalid-ack.json" "$work/oci-index.json"; then
    printf 'invalid %s checkpoint was accepted\n' "$invalid" >&2
    exit 1
  fi
  [[ ! -s "$GH_LOG" ]] || { printf 'invalid %s checkpoint called GitHub\n' "$invalid" >&2; exit 1; }
  [[ ! -e "$work/invalid-ack.json" ]] || { printf 'invalid %s checkpoint was acknowledged\n' "$invalid" >&2; exit 1; }
done

# A complete checkpoint with current findings reopens the canonical issue and
# materializes every finding before persisting and acknowledging its revision.
# Feed IDs and finding platforms are sets, not lexically ordered protocol fields.
active_delivery=$(printf active-finding | sha256sum | cut -d' ' -f1)
active_checkpoint=$(printf checkpoint-active | sha256sum | cut -d' ' -f1)
active_sha=$(printf checkpoint-active-payload | sha256sum | cut -d' ' -f1)
jq --arg checkpoint "$active_checkpoint" --arg sha "$active_sha" --arg delivery "$active_delivery" '
  .checkpoint.checkpoint_id = $checkpoint |
  .checkpoint.revision = 2 |
  .checkpoint.payload_sha256 = $sha |
  .checkpoint.coverage.feed_checkpoint_ids = [("f" * 64),("a" * 64)] |
  .checkpoint.findings = [{delivery_id:$delivery,package_name:"openssl",ecosystem:"Alpine:v3.23",
    version:"3.1.2",vuln_id:"CVE-CURRENT",severity:"high",platforms:["linux/arm64","linux/amd64"]}]
' "$work/checkpoint.json" > "$work/active-checkpoint.json"
rehash_checkpoint "$work/active-checkpoint.json"
active_sha=$(jq -r .checkpoint.payload_sha256 "$work/active-checkpoint.json")
: > "$GH_LOG"
: > "$GH_BODY_LOG"
rm -f "$work/active-ack.json"
export ISSUES="[[{\"number\":8,\"state\":\"closed\",\"body\":\"$v2_image_marker\",\"user\":{\"login\":\"github-actions[bot]\"}}]]"
export COMMENTS_8='[]'
PATH="$work/bin:$PATH" "$root/scripts/monitor_sboms.sh" \
  "$work/wakeup.json" "$work/active-checkpoint.json" "$work/active-ack.json" "$work/oci-index.json"
grep -Fq 'issue reopen 8 --repo owner/repo' "$GH_LOG"
if grep -Fq 'issue close 8' "$GH_LOG"; then
  printf 'current checkpoint findings closed the issue\n' >&2
  exit 1
fi
grep -Fq "<!-- squawk-delivery:$active_delivery -->" "$GH_BODY_LOG"
grep -Fq "<!-- squawk-applied:11:22:2:$active_sha -->" "$GH_BODY_LOG"

# Exact revision replay is an idempotent ACK-only path. The same revision with a
# different digest and any older revision are rejected before issue mutation.
export COMMENTS_8="[{\"body\":\"<!-- squawk-applied:11:22:2:$active_sha -->\",\"user\":{\"login\":\"github-actions[bot]\"}}]"
: > "$GH_LOG"
rm -f "$work/replay-ack.json"
PATH="$work/bin:$PATH" "$root/scripts/monitor_sboms.sh" \
  "$work/wakeup.json" "$work/active-checkpoint.json" "$work/replay-ack.json" "$work/oci-index.json"
if grep -Eq '^issue (create|edit|comment|close|reopen)' "$GH_LOG"; then
  printf 'checkpoint replay mutated an issue\n' >&2
  exit 1
fi
cmp "$work/active-ack.json" "$work/replay-ack.json"

conflicting_checkpoint=$(printf conflicting-checkpoint | sha256sum | cut -d' ' -f1)
jq --arg checkpoint "$conflicting_checkpoint" '.checkpoint.checkpoint_id = $checkpoint' \
  "$work/active-checkpoint.json" > "$work/conflicting-checkpoint.json"
rehash_checkpoint "$work/conflicting-checkpoint.json"
: > "$GH_LOG"
rm -f "$work/conflicting-ack.json"
if PATH="$work/bin:$PATH" "$root/scripts/monitor_sboms.sh" \
  "$work/wakeup.json" "$work/conflicting-checkpoint.json" "$work/conflicting-ack.json" "$work/oci-index.json"; then
  printf 'conflicting checkpoint revision was accepted\n' >&2
  exit 1
fi
[[ ! -e "$work/conflicting-ack.json" ]]

newer_sha=$(printf newer | sha256sum | cut -d' ' -f1)
export COMMENTS_8="[{\"body\":\"<!-- squawk-applied:11:22:3:$newer_sha -->\",\"user\":{\"login\":\"github-actions[bot]\"}}]"
: > "$GH_LOG"
rm -f "$work/older-ack.json"
if PATH="$work/bin:$PATH" "$root/scripts/monitor_sboms.sh" \
  "$work/wakeup.json" "$work/active-checkpoint.json" "$work/older-ack.json" "$work/oci-index.json"; then
  printf 'older checkpoint revision was accepted\n' >&2
  exit 1
fi
[[ ! -e "$work/older-ack.json" ]]

# Authoritative retirement has its own non-security closure reason and ACK.
retirement_checkpoint=$(printf retirement | sha256sum | cut -d' ' -f1)
retirement_sha=$(printf retirement-payload | sha256sum | cut -d' ' -f1)
replacement="ghcr.io/tektum/demo@sha256:$(printf replacement | sha256sum | cut -d' ' -f1)"
jq -n --arg checkpoint "$retirement_checkpoint" --arg sha "$retirement_sha" \
  --arg image "$v2_image" --arg replacement "$replacement" '
  {schema_version:2,state:"ready",checkpoint:{checkpoint_id:$checkpoint,revision:3,
    payload_sha256:$sha,logical_image_ref:$image,
    source:{installation_id:"11",repository_id:"22",ingestion_delivery_id:"ingestion-2"},
    kind:"retirement",retired_at:1999999900,authoritative_source_event_id:"publication-2",
    replacement:{logical_image_ref:$replacement,published_at:1999999800,
      run_url:"https://github.com/tektum/verity-images/actions/runs/123"}}}' > "$work/retirement.json"
rehash_checkpoint "$work/retirement.json"
retirement_sha=$(jq -r .checkpoint.payload_sha256 "$work/retirement.json")
rm -f "$work/invalid-retirement-ack.json"
jq 'del(.checkpoint.authoritative_source_event_id)' "$work/retirement.json" \
  > "$work/invalid-retirement.json"
rehash_checkpoint "$work/invalid-retirement.json"
: > "$GH_LOG"
if PATH="$work/bin:$PATH" "$root/scripts/monitor_sboms.sh" \
  "$work/wakeup.json" "$work/invalid-retirement.json" "$work/invalid-retirement-ack.json"; then
  printf 'retirement without authoritative evidence was accepted\n' >&2
  exit 1
fi
[[ ! -s "$GH_LOG" ]]
[[ ! -e "$work/invalid-retirement-ack.json" ]]
: > "$GH_LOG"
: > "$GH_BODY_LOG"
export ISSUES="[[{\"number\":8,\"state\":\"open\",\"body\":\"$v2_image_marker\",\"user\":{\"login\":\"github-actions[bot]\"}}]]"
export COMMENTS_8="[{\"body\":\"<!-- squawk-applied:11:22:2:$active_sha -->\",\"user\":{\"login\":\"github-actions[bot]\"}}]"
PATH="$work/bin:$PATH" "$root/scripts/monitor_sboms.sh" \
  "$work/wakeup.json" "$work/retirement.json" "$work/retirement-ack.json"
grep -Fq 'issue close 8 --repo owner/repo --reason not\ planned' "$GH_LOG"
grep -Fq 'Historical retirement is not evidence' "$work/bodies/issue-edit.md"
grep -Fq "<!-- squawk-applied:11:22:3:$retirement_sha -->" "$GH_BODY_LOG"
unset NOW_EPOCH_SECONDS COMMENTS_8
