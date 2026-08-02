#!/bin/bash
set -euo pipefail

[[ $# -eq 3 ]]

artifact_json=$1
output_digest=$2
run_id=$3

[[ "$output_digest" =~ ^[0-9a-f]{64}$ ]]
[[ "$run_id" =~ ^[0-9]+$ ]]

jq -e --arg digest "sha256:$output_digest" --argjson run_id "$run_id" '
  .expired == false and
  .workflow_run.id == $run_id and
  (.digest | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
  .digest == $digest
' "$artifact_json" >/dev/null
