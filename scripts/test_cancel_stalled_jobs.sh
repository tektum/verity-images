#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"

fresh_started=$(date -u -d '-2 minutes' +"%Y-%m-%dT%H:%M:%SZ")
stalled_started=$(date -u -d '-25 minutes' +"%Y-%m-%dT%H:%M:%SZ")
running_started=$(date -u -d '-25 minutes' +"%Y-%m-%dT%H:%M:%SZ")

cat > "$work/bin/gh" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%q ' "$@" >> "$GH_LOG"
printf '\n' >> "$GH_LOG"
if [[ "$1 $2" == "api -X" ]]; then
  exit 0
elif [[ "$1" == api ]]; then
  filter=.
  for ((index = 1; index <= $#; index++)); do
    if [[ ${!index} == --jq ]]; then
      filter_index=$((index + 1))
      filter=${!filter_index}
    fi
  done
  jq -c --slurp "$filter" <<<"$JOBS_PAGE"
fi
EOF
chmod +x "$work/bin/gh"
export GH_LOG="$work/gh.log"
export REPOSITORY=owner/repo
export RUN_ID=123
export STALL_MINUTES=20

# One job never picked up a runner past the threshold: cancel it, then report done.
JOBS_PAGE=$(jq -n -c \
  --arg started "$stalled_started" \
  '{jobs: [{id: 1, name: "publish (haproxy-ingress, images/haproxy-ingress, desc)", status: "in_progress", started_at: $started, steps: []}]}')
export JOBS_PAGE
: > "$GH_LOG"
output=$(PATH="$work/bin:$PATH" "$root/scripts/cancel_stalled_jobs.sh")
grep -Fq 'api -X POST repos/owner/repo/actions/jobs/1/cancel' "$GH_LOG"
grep -Fq '::error title=Runner allocation stalled::' <<<"$output"

# A job that has started executing steps is left alone even if old: caller keeps polling.
JOBS_PAGE=$(jq -n -c \
  --arg started "$running_started" \
  '{jobs: [{id: 2, name: "publish (etcd, images/etcd, desc)", status: "in_progress", started_at: $started,
    steps: [{name: "Set up job", status: "completed"}, {name: "Build candidate", status: "in_progress"}]}]}')
export JOBS_PAGE
: > "$GH_LOG"
status=0
PATH="$work/bin:$PATH" "$root/scripts/cancel_stalled_jobs.sh" || status=$?
[[ "$status" -eq 42 ]]
if grep -q '/cancel' "$GH_LOG"; then
  printf 'a genuinely running job was cancelled\n' >&2
  exit 1
fi

# A job that has not yet reached the threshold is left alone: caller keeps polling.
JOBS_PAGE=$(jq -n -c \
  --arg started "$fresh_started" \
  '{jobs: [{id: 3, name: "validate (envoy, images/envoy, desc)", status: "queued", started_at: $started, steps: []}]}')
export JOBS_PAGE
: > "$GH_LOG"
status=0
PATH="$work/bin:$PATH" "$root/scripts/cancel_stalled_jobs.sh" || status=$?
[[ "$status" -eq 42 ]]
if grep -q '/cancel' "$GH_LOG"; then
  printf 'a fresh job was cancelled before the stall threshold\n' >&2
  exit 1
fi

# Completed jobs and unrelated job names never trigger a cancel; nothing left to watch is done.
JOBS_PAGE=$(jq -n -c \
  --arg started "$stalled_started" \
  '{jobs: [
    {id: 4, name: "publish (terraform, images/terraform, desc)", status: "completed", started_at: $started, steps: []},
    {id: 5, name: "build-gate", status: "in_progress", started_at: $started, steps: []}
  ]}')
export JOBS_PAGE
: > "$GH_LOG"
PATH="$work/bin:$PATH" "$root/scripts/cancel_stalled_jobs.sh"
if grep -q '/cancel' "$GH_LOG"; then
  printf 'an unrelated or completed job was cancelled\n' >&2
  exit 1
fi
