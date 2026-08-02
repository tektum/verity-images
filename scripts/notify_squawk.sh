#!/bin/bash
set -euo pipefail

target=${1:?usage: notify_squawk.sh TARGET INDEX_DIGEST AMD64_DIGEST ARM64_DIGEST}
index_digest=${2:?usage: notify_squawk.sh TARGET INDEX_DIGEST AMD64_DIGEST ARM64_DIGEST}
declare -A digests=(
  [amd64]=${3:?usage: notify_squawk.sh TARGET INDEX_DIGEST AMD64_DIGEST ARM64_DIGEST}
  [arm64]=${4:?usage: notify_squawk.sh TARGET INDEX_DIGEST AMD64_DIGEST ARM64_DIGEST}
)
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_SHA:?GITHUB_SHA is required}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"

for arch in amd64 arm64; do
  platform=linux/$arch
  platform_digest=${digests[$arch]}
  payload=$(jq -nc --arg platform "$platform" --arg image_ref "${target}@${platform_digest}" \
    --arg logical_image_ref "${target}@${index_digest}" --arg subject_digest "$platform_digest" \
    '{schema_version:1,platform:$platform,image_ref:$image_ref,logical_image_ref:$logical_image_ref,subject_digest:$subject_digest}')
  jq -nc --arg ref "$GITHUB_SHA" --arg task squawk-sbom --arg environment "squawk-sbom-$arch" \
    --argjson payload "$payload" \
    '{ref:$ref,task:$task,environment:$environment,auto_merge:false,required_contexts:[],payload:$payload}' |
    curl -fsS -X POST -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2026-03-10' \
      -H 'Content-Type: application/json' --data-binary @- \
      "https://api.github.com/repos/${GITHUB_REPOSITORY}/deployments" >/dev/null
done
