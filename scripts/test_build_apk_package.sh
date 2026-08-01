#!/bin/bash
set -euo pipefail

script=$(cd "$(dirname "$0")" && pwd)/build_apk_package.sh

bash -n "$script"
grep -Fq 'x86_64) expected_machine=x86_64 ;;' "$script"
grep -Fq 'aarch64) expected_machine=aarch64 ;;' "$script"
grep -Fq 'melange build packages/openssl-fips-provider/melange.yaml' "$script"
grep -Fq 'scripts/test_fips_runtime.sh ' "$script"
