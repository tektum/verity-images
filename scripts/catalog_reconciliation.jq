# Plan completed build reports without advancing the catalog checkpoint past a
# still-running older build. Completed runs above a gap remain candidates, but
# the frontier stays below the gap so they are safely reconsidered later.
def terminal: .status == "completed";

unique_by(.id)
| sort_by(.id)
| . as $runs
| [$runs[] | select(.id > $low and .id <= $high)] as $window
| (first($window[] | select(terminal | not) | .id) // null) as $gap
| (
    [$window[] | select($gap == null or .id < $gap) | .id]
    | max // $low
  ) as $frontier
| (
    [$window[] | select(terminal)]
    + (if $forced == null then [] else [$forced] end)
    | unique_by(.id)
    | sort_by(.id)
  ) as $candidates
| {
    frontier: $frontier,
    frontierRun: (first($runs[] | select(.id == $frontier)) // null),
    candidates: $candidates
  }
