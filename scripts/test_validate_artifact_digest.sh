#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
validator="$root/.github/scripts/validate-artifact-digest.sh"
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM

digest=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

write_artifact() {
  printf '{"expired":false,"workflow_run":{"id":%s},"digest":"%s"}\n' "${2:-42}" "$1" > "$work_dir/artifact.json"
}

expect_reject() {
  if bash "$validator" "$work_dir/artifact.json" "$1" 42; then
    exit 1
  fi
}

write_artifact "sha256:$digest"
bash "$validator" "$work_dir/artifact.json" "$digest" 42

expect_reject "${digest^^}"
write_artifact "sha512:$digest"
expect_reject "$digest"
write_artifact "sha256:${digest^^}"
expect_reject "$digest"
write_artifact "sha256:${digest:1}"
expect_reject "$digest"
write_artifact "sha256:${digest}0"
expect_reject "$digest"
write_artifact "sha256:$digest"
expect_reject "${digest%?}0"
write_artifact "sha256:$digest" 43
expect_reject "$digest"
