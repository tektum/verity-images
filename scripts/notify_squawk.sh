#!/bin/bash
set -euo pipefail

target=${1:?usage: notify_squawk.sh TARGET INDEX_DIGEST AMD64_BUNDLE AMD64_DIGEST ARM64_BUNDLE ARM64_DIGEST}
index_digest=${2:?usage: notify_squawk.sh TARGET INDEX_DIGEST AMD64_BUNDLE AMD64_DIGEST ARM64_BUNDLE ARM64_DIGEST}
declare -A bundles=(
  [amd64]=${3:?usage: notify_squawk.sh TARGET INDEX_DIGEST AMD64_BUNDLE AMD64_DIGEST ARM64_BUNDLE ARM64_DIGEST}
  [arm64]=${5:?usage: notify_squawk.sh TARGET INDEX_DIGEST AMD64_BUNDLE AMD64_DIGEST ARM64_BUNDLE ARM64_DIGEST}
)
declare -A digests=(
  [amd64]=${4:?usage: notify_squawk.sh TARGET INDEX_DIGEST AMD64_BUNDLE AMD64_DIGEST ARM64_BUNDLE ARM64_DIGEST}
  [arm64]=${6:?usage: notify_squawk.sh TARGET INDEX_DIGEST AMD64_BUNDLE AMD64_DIGEST ARM64_BUNDLE ARM64_DIGEST}
)
: "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:?ACTIONS_ID_TOKEN_REQUEST_TOKEN is required}"
: "${ACTIONS_ID_TOKEN_REQUEST_URL:?ACTIONS_ID_TOKEN_REQUEST_URL is required}"
: "${GITHUB_REPOSITORY_ID:?GITHUB_REPOSITORY_ID is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_SHA:?GITHUB_SHA is required}"
: "${GITHUB_REF:?GITHUB_REF is required}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"

for arch in amd64 arm64; do
  platform=linux/$arch
  bundle=${bundles[$arch]}
  platform_digest=${digests[$arch]}
  statement_hash=$(jq -er '.dsseEnvelope.payload' "$bundle" | base64 -d | sha256sum | cut -d' ' -f1)
  audience="urn:squawk:v1:${GITHUB_REPOSITORY_ID}:${GITHUB_SHA}:${platform//\//%2F}:${platform_digest}:${index_digest}:${statement_hash}"
  encoded_audience=$(jq -rn --arg value "$audience" '$value | @uri')
  oidc=$(curl -fsS -H "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${encoded_audience}" | jq -er .value)
  payload=$(jq -nc --arg image "$target" --arg platform "$platform" \
    --arg image_digest "$platform_digest" --arg index_digest "$index_digest" \
    --arg statement_sha256 "$statement_hash" --arg oidc_token "$oidc" \
    '{schema_version:1,image:$image,platform:$platform,image_digest:$image_digest,index_digest:$index_digest,statement_sha256:$statement_sha256,oidc_token:$oidc_token}')
  jq -nc --arg ref "$GITHUB_REF" --arg task squawk-sbom --arg environment "squawk-sbom-$arch" \
    --argjson payload "$payload" \
    '{ref:$ref,task:$task,environment:$environment,auto_merge:false,required_contexts:[],payload:$payload}' |
    curl -fsS -X POST -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2026-03-10' \
      -H 'Content-Type: application/json' --data-binary @- \
      "https://api.github.com/repos/${GITHUB_REPOSITORY}/deployments" >/dev/null
done
