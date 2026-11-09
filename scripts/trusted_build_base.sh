#!/bin/bash
# Print the trusted changed-image delta base for main: the head commit of the newest
# fully successful main push Build run that is an ancestor of HEAD (or of $1).
#
# A push run only builds the commits it diffs, and GitHub keeps one pending run per
# concurrency group, so a replaced pending run never builds its delta. A run that
# concluded success built and published every image in its delta. Diffing from its
# head therefore covers every commit whose run was replaced, failed, or only
# partially published. The base comes only from main push runs of this repository
# and the local main history, never from pull request input.
set -euo pipefail

repository=${REPOSITORY:?REPOSITORY is required}
head=${1:-HEAD}

runs=$(gh api \
  "repos/${repository}/actions/workflows/build.yaml/runs?branch=main&event=push&status=success&per_page=100")

while IFS=$'\t' read -r sha run_url; do
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || continue
  if git merge-base --is-ancestor "$sha" "$head" 2>/dev/null; then
    printf 'Trusted delta base %s from %s\n' "$sha" "$run_url" >&2
    printf '%s\n' "$sha"
    exit 0
  fi
done < <(jq -r --arg repository "$repository" '
  .workflow_runs
  | map(select(
      .event == "push" and .head_branch == "main" and .status == "completed" and
      .conclusion == "success" and .head_repository.full_name == $repository
    ))
  | sort_by(.created_at) | reverse
  | .[] | [.head_sha, .html_url] | @tsv
' <<<"$runs")

printf '::error title=No trusted delta base::No successful main push Build run among the latest 100 is an ancestor of %s.\n' \
  "$head" >&2
exit 1
