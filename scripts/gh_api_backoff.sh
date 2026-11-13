#!/bin/bash
set -euo pipefail

# Run `gh api ARGS...` and back off on a GitHub rate-limit response instead of
# failing on the first one. Every workflow token in this repository shares one
# installation budget, so a burst from one workflow (catalog discovery, the
# stall guard) otherwise fails unrelated jobs until the hour resets.
#
# On a rate-limit response, wait until the reported reset (primary limit). For
# a secondary limit (or an unknown reset) follow GitHub's guidance for a missing
# retry-after: wait GH_RATE_LIMIT_SECONDARY_WAIT seconds (at least one minute),
# doubling on each further secondary limit. gh does not surface the error
# response's headers without mixing them into stdout, so retry-after itself is
# not read. Spend at most GH_RATE_LIMIT_MAX_WAIT seconds in total. Exit 75
# (EX_TEMPFAIL) when the limit does not reset within that budget so each caller
# decides whether to fail or degrade. Any other failure is not retried here and
# keeps gh's exit status. Output is emitted only on success, so a paginated call
# that is cut off mid-way never leaks partial pages.
max_wait=${GH_RATE_LIMIT_MAX_WAIT:-600}
secondary_wait=${GH_RATE_LIMIT_SECONDARY_WAIT:-60}

out=$(mktemp)
err=$(mktemp)
trap 'rm -f "$out" "$err"' EXIT

waited=0
secondary_delay=$secondary_wait
while :; do
  status=0
  gh api "$@" >"$out" 2>"$err" || status=$?
  cat "$err" >&2
  if (( status == 0 )); then
    cat "$out"
    exit 0
  fi
  if ! grep -qi 'rate limit' "$err"; then
    exit "$status"
  fi

  # The rate_limit endpoint does not count against the primary limit.
  delay=$secondary_delay
  secondary=true
  if core=$(gh api rate_limit --jq '.resources.core | "\(.remaining) \(.reset)"' 2>/dev/null); then
    read -r remaining reset <<<"$core"
    if [[ "$remaining" == 0 && "$reset" =~ ^[0-9]+$ ]]; then
      delay=$(( reset - $(date -u +%s) + 1 ))
      (( delay > 0 )) || delay=1
      secondary=false
    fi
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
