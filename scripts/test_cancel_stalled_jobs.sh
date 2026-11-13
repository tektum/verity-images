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
if [[ "$1 $2" == "api rate_limit" ]]; then
  # The caller asks for `.resources.core | "\(.remaining) \(.reset)"`.
  printf '%s %s\n' "${RATE_LIMIT_REMAINING:-0}" "${RATE_LIMIT_RESET:?}"
  exit 0
elif [[ "$1 $2" == "api -X" ]]; then
  exit 0
elif [[ "$1" == api ]]; then
  # Fail the first RATE_LIMITED_CALLS job listings with RATE_LIMIT_ERROR, or
  # every listing with API_ERROR.
  limited=$(grep -c -- '--paginate' "$GH_LOG" || true)
  if (( limited <= ${RATE_LIMITED_CALLS:-0} )); then
    printf 'gh: %s\n' "$RATE_LIMIT_ERROR" >&2
    exit 1
  fi
  if [[ -n "${API_ERROR:-}" ]]; then
    printf 'gh: %s\n' "$API_ERROR" >&2
    exit 1
  fi
  args=" $* "
  if [[ "$args" != *" --paginate "* || "$args" != *" --slurp "* ]]; then
    printf 'the `--paginate` and `--slurp` options are required\n' >&2
    exit 1
  fi
  if [[ "$args" == *" --jq "* || "$args" == *" --template "* ]]; then
    printf 'the `--slurp` option is not supported with `--jq` or `--template`\n' >&2
    exit 1
  fi
  jq -c --slurp '.' <<<"$JOBS_PAGE"
fi
EOF
chmod +x "$work/bin/gh"
export GH_LOG="$work/gh.log"
export REPOSITORY=owner/repo
export RUN_ID=123
export STALL_MINUTES=20

# A job on the second API page never picked up a runner past the threshold:
# flatten every page, cancel it, then report done.
JOBS_PAGE=$(jq -n -c \
  --arg started "$stalled_started" \
  '{jobs: [{id: 0, name: "build-gate", status: "in_progress", started_at: $started, steps: []}]},
   {jobs: [{id: 1, name: "publish (haproxy-ingress, images/haproxy-ingress, desc)", status: "in_progress", started_at: $started, steps: []}]}')
export JOBS_PAGE
: > "$GH_LOG"
status=0
output=$(PATH="$work/bin:$PATH" "$root/scripts/cancel_stalled_jobs.sh") || status=$?
[[ "$status" -eq 1 ]]
grep -Fq 'api -X POST repos/owner/repo/actions/runs/123/cancel' "$GH_LOG"
if grep -q '/actions/jobs/' "$GH_LOG"; then
  echo 'job-level cancel endpoint does not exist and must not be called' >&2
  exit 1
fi
grep -Fq '::error title=Runner allocation stalled::' <<<"$output"

# Publication runs in the reusable publish.yaml, so GitHub names its rows
# "publish / publish (...)". A stalled row under that name is still cancelled.
JOBS_PAGE=$(jq -n -c \
  --arg started "$stalled_started" \
  '{jobs: [{id: 5, name: "publish / publish (caddy, images/caddy, desc)", status: "queued", started_at: $started, steps: []}]}')
export JOBS_PAGE
: > "$GH_LOG"
status=0
PATH="$work/bin:$PATH" "$root/scripts/cancel_stalled_jobs.sh" >/dev/null || status=$?
[[ "$status" -eq 1 ]]
grep -Fq 'api -X POST repos/owner/repo/actions/runs/123/cancel' "$GH_LOG"

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

# The jobs API returns "steps": null for a job that was just created or is still
# waiting. That means no steps started: keep polling while young, cancel once old.
JOBS_PAGE=$(jq -n -c \
  --arg started "$fresh_started" \
  '{jobs: [{id: 6, name: "publish (nats, images/nats, desc)", status: "queued", started_at: $started, steps: null}]}')
export JOBS_PAGE
: > "$GH_LOG"
status=0
PATH="$work/bin:$PATH" "$root/scripts/cancel_stalled_jobs.sh" || status=$?
[[ "$status" -eq 42 ]]
if grep -q '/cancel' "$GH_LOG"; then
  printf 'a fresh job with null steps was cancelled\n' >&2
  exit 1
fi

JOBS_PAGE=$(jq -n -c \
  --arg started "$stalled_started" \
  '{jobs: [{id: 7, name: "publish (nats, images/nats, desc)", status: "queued", started_at: $started, steps: null}]}')
export JOBS_PAGE
: > "$GH_LOG"
status=0
PATH="$work/bin:$PATH" "$root/scripts/cancel_stalled_jobs.sh" >/dev/null || status=$?
[[ "$status" -eq 1 ]]
grep -Fq 'api -X POST repos/owner/repo/actions/runs/123/cancel' "$GH_LOG"

# A malformed API payload is retried briefly, then fails loudly (1, not 42, so
# the caller stops instead of polling for hours) and never cancels.
export LIST_JOBS_ATTEMPTS=2 LIST_JOBS_RETRY_SECONDS=0
JOBS_PAGE='not json'
export JOBS_PAGE
: > "$GH_LOG"
status=0
PATH="$work/bin:$PATH" "$root/scripts/cancel_stalled_jobs.sh" >/dev/null 2>&1 || status=$?
[[ "$status" -eq 1 ]]
if grep -q '/cancel' "$GH_LOG"; then
  printf 'a malformed payload triggered a cancel\n' >&2
  exit 1
fi

# No validate/publish jobs visible yet (API hasn't caught up with matrix's
# output): treat as pending rather than declaring done prematurely.
JOBS_PAGE=$(jq -n -c '{jobs: []}')
export JOBS_PAGE
: > "$GH_LOG"
status=0
PATH="$work/bin:$PATH" "$root/scripts/cancel_stalled_jobs.sh" || status=$?
[[ "$status" -eq 42 ]]
if grep -q '/cancel' "$GH_LOG"; then
  printf 'an empty job list still triggered a cancel\n' >&2
  exit 1
fi

# Every native row is terminal but validate/publish rows do not exist yet: keep
# watching, or runner starvation of the deferred rows would go unguarded.
JOBS_PAGE=$(jq -n -c \
  --arg started "$stalled_started" \
  '{jobs: [{id: 6, name: "native-arm64 (etcd, images/etcd, desc)", status: "completed", started_at: $started, steps: []}]}')
export JOBS_PAGE
: > "$GH_LOG"
status=0
PATH="$work/bin:$PATH" "$root/scripts/cancel_stalled_jobs.sh" || status=$?
[[ "$status" -eq 42 ]]

# A native row that never got a runner is cancelled like any other watched job.
JOBS_PAGE=$(jq -n -c \
  --arg started "$stalled_started" \
  '{jobs: [{id: 7, name: "native-arm64 (etcd, images/etcd, desc)", status: "queued", started_at: $started, steps: []}]}')
export JOBS_PAGE
: > "$GH_LOG"
status=0
output=$(PATH="$work/bin:$PATH" "$root/scripts/cancel_stalled_jobs.sh") || status=$?
[[ "$status" -eq 1 ]]
grep -Fq 'api -X POST repos/owner/repo/actions/runs/123/cancel' "$GH_LOG"
grep -Fq '::error title=Runner allocation stalled::' <<<"$output"

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

# The workflow token shares one installation-wide budget. A rate-limited job
# listing waits for the reported reset and then guards as usual.
pending_page=$(jq -n -c \
  --arg started "$fresh_started" \
  '{jobs: [{id: 8, name: "publish (nats, images/nats, desc)", status: "queued", started_at: $started, steps: null}]}')
export JOBS_PAGE=$pending_page
export RATE_LIMIT_ERROR='API rate limit exceeded for installation. If you reach out to GitHub Support for help, please include the request ID 0000:0000'
export RATE_LIMITED_CALLS=1 RATE_LIMIT_RESET
RATE_LIMIT_RESET=$(date -u +%s)
: > "$GH_LOG"
status=0
GH_RATE_LIMIT_MAX_WAIT=5 PATH="$work/bin:$PATH" "$root/scripts/cancel_stalled_jobs.sh" >/dev/null 2>&1 || status=$?
[[ "$status" -eq 42 ]]
[[ "$(grep -c -- '--paginate' "$GH_LOG")" -eq 2 ]]
grep -Fq 'api rate_limit' "$GH_LOG"

# A reset beyond the wait budget warns and reports pending (42) instead of
# failing the run, so the caller polls again later. It neither sleeps until the
# reset nor cancels anything.
export RATE_LIMITED_CALLS=99
RATE_LIMIT_RESET=$(( $(date -u +%s) + 3600 ))
: > "$GH_LOG"
status=0
started=$(date -u +%s)
output=$(GH_RATE_LIMIT_MAX_WAIT=5 PATH="$work/bin:$PATH" "$root/scripts/cancel_stalled_jobs.sh" 2>/dev/null) ||
  status=$?
[[ "$status" -eq 42 ]]
grep -Fq '::warning title=Stall guard paused::' <<<"$output"
(( $(date -u +%s) - started < 5 ))
if grep -q '/cancel' "$GH_LOG"; then
  printf 'a rate-limited guard cancelled the run\n' >&2
  exit 1
fi

# A secondary rate limit (core budget left) backs off for the fixed delay.
export RATE_LIMITED_CALLS=1 RATE_LIMIT_REMAINING=4000
export RATE_LIMIT_ERROR='You have exceeded a secondary rate limit. Please wait a few minutes before you try again.'
: > "$GH_LOG"
status=0
GH_RATE_LIMIT_MAX_WAIT=5 GH_RATE_LIMIT_SECONDARY_WAIT=1 PATH="$work/bin:$PATH" \
  "$root/scripts/cancel_stalled_jobs.sh" >/dev/null 2>&1 || status=$?
[[ "$status" -eq 42 ]]
[[ "$(grep -c -- '--paginate' "$GH_LOG")" -eq 2 ]]
unset RATE_LIMIT_REMAINING

# Any other API error still fails closed as before (1 after the retries, not 0
# and not 42), and never waits on the rate-limit budget.
export RATE_LIMITED_CALLS=0
export API_ERROR='HTTP 403: Resource not accessible by integration'
: > "$GH_LOG"
status=0
PATH="$work/bin:$PATH" "$root/scripts/cancel_stalled_jobs.sh" >/dev/null 2>&1 || status=$?
[[ "$status" -eq 1 ]]
[[ "$(grep -c -- '--paginate' "$GH_LOG")" -eq "$LIST_JOBS_ATTEMPTS" ]]
if grep -q 'rate_limit' "$GH_LOG"; then
  printf 'a non-rate-limit error consulted the rate-limit budget\n' >&2
  exit 1
fi
unset API_ERROR
