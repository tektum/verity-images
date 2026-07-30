#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
sample='build-1-amd64: digest: sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa size: 426'
actual=$(printf '%s\n' "$sample" | "$root/scripts/parse_push_digest.sh")
[[ "$actual" == sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]]
if printf '%s\n' 'build-1-amd64: digest: invalid size: 426' | "$root/scripts/parse_push_digest.sh"; then
  printf 'invalid push digest was accepted\n' >&2
  exit 1
fi
