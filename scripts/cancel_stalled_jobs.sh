#!/bin/bash
set -euo pipefail

repository=${REPOSITORY:?REPOSITORY is required}
run_id=${RUN_ID:?RUN_ID is required}
stall_minutes=${STALL_MINUTES:?STALL_MINUTES is required}
now=$(date -u +%s)

jobs=$(gh api --paginate --slurp "repos/${repository}/actions/runs/${run_id}/jobs?per_page=100" \
  --jq '[.[].jobs[]] | map(select(.name | test("^(validate|publish) \\(")))')

pending=false
while IFS= read -r job; do
  [[ -n "$job" ]] || continue
  status=$(jq -r .status <<<"$job")
  [[ "$status" == queued || "$status" == in_progress ]] || continue
  started=$(jq -r '.started_at // empty' <<<"$job")
  if [[ -z "$started" ]]; then
    pending=true
    continue
  fi
  begun=$(jq -r '[.steps[] | select(.status != "queued")] | length' <<<"$job")
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
  gh api -X POST "repos/${repository}/actions/jobs/${id}/cancel" >/dev/null
  printf '::error title=Runner allocation stalled::Job "%s" (id %s) had no runner after %sm; cancelling so build-gate can fail fast.\n' \
    "$name" "$id" "$age_minutes"
done < <(jq -c '.[]' <<<"$jobs")

# Exit 0 once every watched job is terminal; exit 42 while any remain so the
# caller keeps polling. Annotations above still go to stdout for GitHub to
# render, so the exit code (not stdout) is the only pending/done signal, and
# 42 is reserved so a genuine script failure (any other non-zero status)
# still aborts the caller's loop instead of being retried forever.
if [[ "$pending" == true ]]; then
  exit 42
fi
