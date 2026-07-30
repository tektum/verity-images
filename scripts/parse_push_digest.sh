#!/bin/bash
set -euo pipefail

digest=$(awk '/digest: sha256:/ {print $3}')
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]
printf '%s\n' "$digest"
