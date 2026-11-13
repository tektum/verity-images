#!/bin/bash
set -euo pipefail

repository=${REPOSITORY:?REPOSITORY is required}
run_id=${RUN_ID:?RUN_ID is required}
stall_minutes=${STALL_MINUTES:?STALL_MINUTES is required}

# A transient API or parse failure must not abort the guard on the first try
# (that leaves the run unguarded), but a permanent one (401/403/404, schema
# error) must not poll for hours either: the caller retries 42 until the job
# timeout while the run holds the concurrency group. Retry briefly in-process,
# then fail loudly with a non-42 code.
attempts=${LIST_JOBS_ATTEMPTS:-5}
retry_seconds=${LIST_JOBS_RETRY_SECONDS:-10}
# The guard is best-effort: a rate-limited API must not fail the run it guards.
# Wait for the reset within a bounded budget, then stop guarding with a warning.
export GH_RATE_LIMIT_MAX_WAIT=${GH_RATE_LIMIT_MAX_WAIT:-900}
gh_api=$(dirname "$0")/gh_api_backoff.sh
for ((attempt = 1; ; attempt++)); do
  status=0
  pages=$("$gh_api" --paginate --slurp "repos/${repository}/actions/runs/${run_id}/jobs?per_page=100") ||
    status=$?
  if (( status == 75 )); then
    echo "::warning title=Stall guard stopped::GitHub API rate limit did not reset within ${GH_RATE_LIMIT_MAX_WAIT}s; stopping the best-effort stall guard without failing the run."
    exit 0
  fi
  if (( status == 0 )) && jobs=$(jq '[.[] | (.jobs // [])[]] | map(select(.name | test("^(native-arm64|validate|publish( / publish)?) \\(")))' <<<"$pages"); then
    break
  fi
  if (( attempt >= attempts )); then
    echo "::error title=Stall guard::Could not list jobs after ${attempts} attempts; failing instead of polling forever."
    exit 1
  fi
  sleep "$retry_seconds"
done

# The caller only starts this script once matrix has produced at least one
# image, so an empty result here means the API hasn't caught up with the
# newly created native-arm64/validate/publish jobs yet, not that none exist.
# Treat that as pending too, or a lagging first poll could report DONE before
# those jobs are even visible.
if [[ "$(jq 'length' <<<"$jobs")" -eq 0 ]]; then
  exit 42
fi

now=$(date -u +%s)
pending=false
stalled=
while IFS= read -r job; do
  [[ -n "$job" ]] || continue
  status=$(jq -r .status <<<"$job")
  [[ "$status" == queued || "$status" == in_progress ]] || continue
  started=$(jq -r '.started_at // empty' <<<"$job")
  if [[ -z "$started" ]]; then
    pending=true
    continue
  fi
  begun=$(jq -r '[(.steps // [])[] | select(.status != "queued")] | length' <<<"$job")
  if [[ "$begun" -gt 0 ]]; then
    pending=true
    continue
  fi
  age_minutes=$(( (now - $(date -u -d "$started" +%s)) / 60 ))
  if (( age_minutes < stall_minutes )); then
    pending=true
    continue
  fi
  id=$(jq -r .id <<<"$job")
  name=$(jq -r .name <<<"$job")
  stalled+=$(printf '::error title=Runner allocation stalled::Job "%s" (id %s) had no runner after %sm; cancelling the run so build-gate can fail fast.\n' \
    "$name" "$id" "$age_minutes")$'\n'
done < <(jq -c '.[]' <<<"$jobs")

# GitHub has no job-level cancel endpoint, so stalled jobs cancel the whole
# run. Leaving them queued would block later main runs (cancel-in-progress is
# false). Exit non-zero (not 42) so this job fails loudly.
if [[ -n "$stalled" ]]; then
  printf '%s' "$stalled"
  "$gh_api" -X POST "repos/${repository}/actions/runs/${run_id}/cancel" >/dev/null
  exit 1
fi

# Exit 0 once every watched job is terminal and a validate/publish row has been
# seen; exit 42 while any remain or none exist yet. validate/publish need
# native-arm64, so their rows appear only after the slowest native compile, and
# an all-terminal native set must not end the watch before they exist. Annotations
# above still go to stdout for GitHub to render, so the exit code (not stdout) is
# the only pending/done signal, and 42 is reserved so a genuine script failure
# (any other non-zero status) still aborts the caller's loop instead of being
# retried forever.
rows=$(jq 'map(select(.name | test("^(validate|publish( / publish)?) \\("))) | length' <<<"$jobs")
if [[ "$pending" == true || "$rows" -eq 0 ]]; then
  exit 42
fi
