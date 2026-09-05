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
    printf '%s\n' "${COMMENTS:-[]}"
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
    fi
  done
  [[ "$1 $2" != "issue create" ]] || printf '%s\n' 'https://github.com/owner/repo/issues/42'
fi
EOF
chmod +x "$work/bin/gh"
export GH_BODY_DIR=$work/bodies
export GH_LOG=$work/gh.log
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
export COMMENTS="[[{\"body\":\"<!-- squawk-delivery:$delivery -->\",\"user\":{\"login\":\"github-actions[bot]\"}}]]"
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
grep -Fq "<!-- squawk-delivery:$second_delivery -->" "$work/bodies/issue-comment.md"
grep -Fq "### \`CVE-SECOND\` in \`libssl3@3.1.3\`" "$work/bodies/issue-comment.md"

# If two deliveries both observe no image issue, a later re-query converges the
# newly created issue on the oldest image issue without dropping this finding.
: > "$GH_LOG"
export COMMENTS='[]'
export ISSUES_FILE="$work/issues-sequence"
cat > "$ISSUES_FILE" <<EOF
[]
[[{"number":8,"state":"open","body":"$image_marker","user":{"login":"github-actions[bot]"}},{"number":42,"state":"open","body":"$image_marker","user":{"login":"github-actions[bot]"}}]]
EOF
PATH="$work/bin:$PATH" "$root/scripts/monitor_sboms.sh" "$work/payload.json"
unset ISSUES_FILE
grep -Fq 'issue create --repo owner/repo' "$GH_LOG"
grep -Fq 'issue edit 8 --repo owner/repo' "$GH_LOG"
grep -Fq 'issue comment 8 --repo owner/repo' "$GH_LOG"
grep -Fq 'issue edit 42 --repo owner/repo --body-file' "$GH_LOG"
grep -Fq 'issue close 42 --repo owner/repo --reason not\ planned' "$GH_LOG"
grep -Fxq '<!-- squawk-consolidated-into:8 -->' "$work/bodies/issue-edit.md"
grep -Fxq 'Consolidated into #8; Squawk tracks one remediation issue per immutable image.' "$work/bodies/issue-edit.md"
close_line=$(grep -nF 'issue close 42' "$GH_LOG" | cut -d: -f1)
edit_line=$(grep -nF 'issue edit 42' "$GH_LOG" | cut -d: -f1)
(( close_line < edit_line )) || { printf 'duplicate marker was erased before close\n' >&2; exit 1; }

# A reconciled duplicate carries no image marker and is not reclaimed if a
# maintainer later reopens it.
: > "$GH_LOG"
export ISSUES="[[{\"number\":8,\"state\":\"open\",\"body\":\"$image_marker\",\"user\":{\"login\":\"github-actions[bot]\"}},{\"number\":42,\"state\":\"open\",\"body\":\"<!-- squawk-consolidated-into:8 -->\",\"user\":{\"login\":\"github-actions[bot]\"}}]]"
PATH="$work/bin:$PATH" "$root/scripts/monitor_sboms.sh" "$work/payload.json"
if grep -Eq 'issue (edit|close) 42' "$GH_LOG"; then
  printf 'reopened consolidated issue was reclaimed\n' >&2
  exit 1
fi

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

jq '.platforms[0].image_ref = "ghcr.io/tektum/demo:latest"' \
  "$work/payload.json" > "$work/invalid.json"
if PATH="$work/bin:$PATH" "$root/scripts/monitor_sboms.sh" "$work/invalid.json"; then
  printf 'mutable image reference was accepted\n' >&2
  exit 1
fi

for invalid in marker severity severity-type severity-vector severity-long; do
  case $invalid in
    marker) jq --arg marker $'openssl\n<!-- squawk-delivery:bad -->' '.package_name = $marker' "$work/payload.json" ;;
    severity) jq '.severity = "urgent"' "$work/payload.json" ;;
    severity-type) jq '.severity = false' "$work/payload.json" ;;
    severity-vector) jq '.severity = "foo:bar/baz:qux"' "$work/payload.json" ;;
    severity-long) jq --arg severity "CVSS:3.1$(printf '/AV:N%.0s' {1..70})" '.severity = $severity' "$work/payload.json" ;;
  esac > "$work/invalid.json"
  : > "$GH_LOG"
  if PATH="$work/bin:$PATH" "$root/scripts/monitor_sboms.sh" "$work/invalid.json"; then
    printf 'invalid %s payload was accepted\n' "$invalid" >&2
    exit 1
  fi
  [[ ! -s "$GH_LOG" ]] || { printf 'invalid %s payload called GitHub\n' "$invalid" >&2; exit 1; }
done
