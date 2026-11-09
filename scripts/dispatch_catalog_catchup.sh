#!/bin/bash
set -euo pipefail

repository=${REPOSITORY:?REPOSITORY is required}

# The catalog source commit is not a safe base: it advances to the newest published
# run even when intermediate commits were never built. Use the shared trusted base.
base_sha=$("$(dirname "$0")/trusted_build_base.sh" HEAD) || {
  printf '::error title=Catalog catch-up skipped::No trusted delta base is available; not dispatching a recovery build.\n'
  exit 1
}

if [[ ! "$base_sha" =~ ^[0-9a-f]{40}$ ]]; then
  printf '::error title=Catalog catch-up skipped::Trusted base "%s" is not a usable SHA; not dispatching a recovery build.\n' \
    "$base_sha"
  exit 1
fi

gh workflow run build.yaml --repo "$repository" --ref main -f "base-sha=${base_sha}"
printf '::error title=Main publish failed; catch-up dispatched::build-gate failed for this push, so a changed-image recovery build was dispatched from base %s. Watch the Actions tab for the new run.\n' \
  "$base_sha"
printf '## Catalog catch-up dispatched\n\nbuild-gate failed for this push. Re-dispatched "build.yaml" with base-sha=%s.\n' \
  "$base_sha" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
