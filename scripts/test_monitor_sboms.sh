#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/bodies"
delivery=$(printf delivery | sha256sum | cut -d' ' -f1)
cat > "$work/payload.json" <<EOF
{
  "schema_version": 1,
  "delivery_id": "$delivery",
  "logical_image_ref": "ghcr.io/tektum/demo@sha256:$(printf index | sha256sum | cut -d' ' -f1)",
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
  printf '%s\n' "${ISSUES:-[]}"
elif [[ "$1 $2" == "issue create" || "$1 $2" == "issue edit" ]]; then
  for ((index=1; index <= $#; index++)); do
    if [[ ${!index} == --body-file ]]; then
      body_index=$((index + 1))
      cp "${!body_index}" "$GH_BODY_DIR/${1}-${2}.md"
    fi
  done
fi
EOF
chmod +x "$work/bin/gh"
export GH_BODY_DIR=$work/bodies
export GH_LOG=$work/gh.log
export GITHUB_REPOSITORY=owner/repo
export RUN_URL=https://example.test/run

PATH="$work/bin:$PATH" "$root/scripts/monitor_sboms.sh" "$work/payload.json"
grep -Fq 'api --paginate --slurp repos/owner/repo/issues\?state=all\&labels=squawk\&per_page=100' "$GH_LOG"
grep -Fq 'label create squawk --repo owner/repo --color 5319E7' "$GH_LOG"
grep -Fq 'issue create --repo owner/repo --title \[CVE\]\ openssl@3.1.2\ CVE-TEST' "$GH_LOG"
grep -Fq -- '--label squawk' "$GH_LOG"
grep -Fq "<!-- squawk-delivery:$delivery -->" "$work/bodies/issue-create.md"
grep -Fq '| linux/amd64 |' "$work/bodies/issue-create.md"

: > "$GH_LOG"
export ISSUES="[[{\"number\":8,\"state\":\"closed\",\"body\":\"<!-- squawk-delivery:$delivery -->\",\"user\":{\"login\":\"github-actions[bot]\"}}]]"
PATH="$work/bin:$PATH" "$root/scripts/monitor_sboms.sh" "$work/payload.json"
grep -Fq 'issue reopen 8 --repo owner/repo' "$GH_LOG"
grep -Fq 'issue edit 8 --repo owner/repo' "$GH_LOG"

# Squawk persists advisory severity as a label, CVSS v2/v3/v4 vector, or null.
# Accepted strings are preserved; null renders as unknown.
for severity in \
  'CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:N/A:H' \
  'CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:N/VC:N/VI:N/VA:H/SC:N/SI:N/SA:N/U:Amber' \
  'AV:N/AC:L/Au:N/C:P/I:P/A:P'; do
  rm -f "$work/bodies/issue-edit.md"
  jq --arg severity "$severity" '.severity = $severity' \
    "$work/payload.json" > "$work/cvss.json"
  PATH="$work/bin:$PATH" "$root/scripts/monitor_sboms.sh" "$work/cvss.json"
  grep -Fq "Severity: $severity" "$work/bodies/issue-edit.md"
done

rm -f "$work/bodies/issue-edit.md"
jq '.severity = null' "$work/payload.json" > "$work/null-severity.json"
PATH="$work/bin:$PATH" "$root/scripts/monitor_sboms.sh" "$work/null-severity.json"
grep -Fq 'Severity: unknown' "$work/bodies/issue-edit.md"

: > "$GH_LOG"
export ISSUES="[[{\"number\":8,\"state\":\"open\",\"body\":\"<!-- squawk-delivery:$delivery -->\"},{\"number\":9,\"state\":\"open\",\"body\":\"<!-- squawk-delivery:$delivery -->\"}]]"
if PATH="$work/bin:$PATH" "$root/scripts/monitor_sboms.sh" "$work/payload.json"; then
  printf 'duplicate delivery issues were accepted\n' >&2
  exit 1
fi
if grep -Eq '^issue (create|edit|reopen)' "$GH_LOG"; then
  printf 'duplicate delivery changed issues\n' >&2
  exit 1
fi

jq '.platforms[0].image_ref = "ghcr.io/tektum/demo:latest"' \
  "$work/payload.json" > "$work/invalid.json"
if PATH="$work/bin:$PATH" "$root/scripts/monitor_sboms.sh" "$work/invalid.json"; then
  printf 'mutable image reference was accepted\n' >&2
  exit 1
fi

for invalid in marker severity severity-type severity-long; do
  case $invalid in
    marker) jq --arg marker $'openssl\n<!-- squawk-delivery:bad -->' '.package_name = $marker' "$work/payload.json" ;;
    severity) jq '.severity = "urgent"' "$work/payload.json" ;;
    severity-type) jq '.severity = false' "$work/payload.json" ;;
    severity-long) jq --arg severity "CVSS:3.1/$(printf 'AB:C%.0s' {1..70})" '.severity = $severity' "$work/payload.json" ;;
  esac > "$work/invalid.json"
  : > "$GH_LOG"
  if PATH="$work/bin:$PATH" "$root/scripts/monitor_sboms.sh" "$work/invalid.json"; then
    printf 'invalid %s payload was accepted\n' "$invalid" >&2
    exit 1
  fi
  [[ ! -s "$GH_LOG" ]] || { printf 'invalid %s payload called GitHub\n' "$invalid" >&2; exit 1; }
done
