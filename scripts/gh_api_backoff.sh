#!/bin/bash
set -euo pipefail

# Run `gh api ARGS...` and back off on a GitHub rate-limit response instead of
# failing on the first one. Every workflow token in this repository shares one
# installation budget, so a burst from one workflow (catalog discovery, the
# stall guard) otherwise fails unrelated jobs until the hour resets.
#
# On a rate-limit response, wait as the response asks: its retry-after, else
# its x-ratelimit-reset when x-ratelimit-remaining is 0. The headers come from
# gh's debug log on stderr, so stdout (JSON pages, artifact ZIPs) stays intact.
# Without those headers, consult `gh api rate_limit` (it does not count against
# the limit), then follow GitHub's fallback: wait GH_RATE_LIMIT_SECONDARY_WAIT
# seconds (at least one minute), doubling on each further secondary limit.
# Spend at most GH_RATE_LIMIT_MAX_WAIT seconds in total. Exit 75 (EX_TEMPFAIL)
# when the limit does not reset within that budget so each caller decides
# whether to fail or degrade. Any other failure is not retried here and keeps
# gh's exit status. Output is emitted only on success, so a paginated call that
# is cut off mid-way never leaks partial pages.
max_wait=${GH_RATE_LIMIT_MAX_WAIT:-600}
secondary_wait=${GH_RATE_LIMIT_SECONDARY_WAIT:-60}

out=$(mktemp)
err=$(mktemp)
trap 'rm -f "$out" "$err"' EXIT

# Last value of one response header in the debug log ("< Name: value").
header() {
  awk -v name="$1" '
    tolower($0) ~ "^< " tolower(name) ":" { sub(/\r$/, ""); value = $NF }
    END { print value }
  ' "$err"
}

waited=0
secondary_delay=$secondary_wait
while :; do
  status=0
  GH_DEBUG=api gh api "$@" >"$out" 2>"$err" || status=$?
  # Keep gh's own messages, not the request/response debug log or bodies.
  messages=$(grep -Ev '^(\* |> |< |[[:space:]]|[][{}"]|$)' "$err" || true)
  [[ -z "$messages" ]] || printf '%s\n' "$messages" >&2
  if (( status == 0 )); then
    cat "$out"
    exit 0
  fi
  if ! grep -qi 'rate limit' <<<"$messages"; then
    exit "$status"
  fi

  secondary=false
  retry_after=$(header retry-after)
  remaining=$(header x-ratelimit-remaining)
  reset=$(header x-ratelimit-reset)
  if [[ -z "$remaining" ]] &&
    core=$(gh api rate_limit --jq '.resources.core | "\(.remaining) \(.reset)"' 2>/dev/null); then
    read -r remaining reset <<<"$core"
  fi
  if [[ "$retry_after" =~ ^[0-9]+$ ]]; then
    delay=$(( retry_after > 0 ? retry_after : 1 ))
  elif [[ "$remaining" == 0 && "$reset" =~ ^[0-9]+$ ]]; then
    delay=$(( reset - $(date -u +%s) + 1 ))
    (( delay > 0 )) || delay=1
  else
    delay=$secondary_delay
    secondary=true
  fi
  if (( waited + delay > max_wait )); then
    printf 'GitHub API rate limit does not reset within the %ss budget (next retry in %ss).\n' \
      "$max_wait" "$delay" >&2
    exit 75
  fi
  printf 'GitHub API rate limit reached; retrying in %ss.\n' "$delay" >&2
  sleep "$delay"
  waited=$(( waited + delay ))
  if [[ "$secondary" == true ]]; then
    secondary_delay=$(( secondary_delay * 2 ))
  fi
done
