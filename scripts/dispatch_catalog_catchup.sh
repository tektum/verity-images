#!/bin/bash
set -euo pipefail

repository=${REPOSITORY:?REPOSITORY is required}
catalog_url=${CATALOG_URL:-https://tektum.github.io/verity-images/catalog.json}

catalog=$(curl --silent --show-error --location --fail \
  --connect-timeout 10 --max-time 30 "$catalog_url")
base_sha=$(jq -r '.source.commit // empty' <<<"$catalog")

if [[ ! "$base_sha" =~ ^[0-9a-f]{40}$ ]]; then
  printf '::error title=Catalog catch-up skipped::Published catalog source commit "%s" is not a usable SHA; not dispatching a recovery build.\n' \
    "$base_sha"
  exit 1
fi

if ! git merge-base --is-ancestor "$base_sha" HEAD; then
  printf '::error title=Catalog catch-up skipped::Published catalog source commit %s is not an ancestor of HEAD; not dispatching a recovery build.\n' \
    "$base_sha"
  exit 1
fi

gh workflow run build.yaml --repo "$repository" --ref main -f "base-sha=${base_sha}"
printf '::error title=Main publish failed; catch-up dispatched::build-gate failed for this push, so a changed-image recovery build was dispatched from base %s. Watch the Actions tab for the new run.\n' \
  "$base_sha"
printf '## Catalog catch-up dispatched\n\nbuild-gate failed for this push. Re-dispatched "build.yaml" with base-sha=%s.\n' \
  "$base_sha" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
