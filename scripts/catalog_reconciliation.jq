# Select the latest attempt for each completed build whose receipt is not yet
# reflected in the catalog. A forced dispatch reapplies its latest attempt even
# when the ledger already records it. Completion time defines merge precedence.
(
  . + (if $forced == null then [] else [$forced] end)
  | sort_by(.id, .run_attempt, .updated_at)
  | group_by(.id)
  | map(max_by(.run_attempt, .updated_at))
) as $runs
| (
    [$runs[]
      | select(.status == "completed")
      | select(
          (($ledger[(.id | tostring)] // 0) < .run_attempt)
          or ($forced != null and .id == $forced.id and .run_attempt == $forced.run_attempt)
        )]
    | sort_by(.updated_at, .id, .run_attempt)
  ) as $candidates
| {candidates: $candidates}
