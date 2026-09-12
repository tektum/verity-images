#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

mapfile -t configs < <(git diff --name-only HEAD -- ':(glob)images/**/apko.yaml')
if (( ${#configs[@]} == 0 )); then
  printf 'error: no changed pure APKO configuration\n' >&2
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for config in "${configs[@]}"; do
  context=${config%/apko.yaml}
  targets="$work/targets.json"
  python3 scripts/gen_apko_lock_targets.py --image "$context" > "$targets"
  lockfile=$(jq -er --arg config "$config" '
    [.images[].locks[] | select(.config == $config)]
    | if length == 1 then .[0].lockfile else empty end
  ' "$targets")
  apko lock "$config" --arch amd64,arm64 --output "$lockfile"
done
