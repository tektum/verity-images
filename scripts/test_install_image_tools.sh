#!/bin/bash
set -euo pipefail

script=$(cd "$(dirname "$0")" && pwd)/install_image_tools.sh
root=$(cd "$(dirname "$0")/.." && pwd)
build_workflow=$root/.github/workflows/build.yaml
apk_workflow=$root/.github/workflows/apk-repository.yaml
apk_exit=$(awk '/track" == apk/ {apk=1} apk && /^  exit$/ {print NR; exit}' "$script")
grype_install=$(awk '/sudo install \/tmp\/grype \/usr\/local\/bin\/grype/ {print NR}' "$script")
wolfi_exit=$(awk '/track" == wolfi/ {wolfi=1} wolfi && /^  exit$/ {print NR; exit}' "$script")
[[ -n "$apk_exit" && -n "$grype_install" && -n "$wolfi_exit" ]]
[[ "$apk_exit" -lt "$grype_install" && "$grype_install" -lt "$wolfi_exit" ]]

grep -Fx '  APKO_VERSION: 1.2.31' "$build_workflow"
grep -Fx '  APKO_SHA256: abd57139139f4f5ce567f914bd168b7b2f4a3d39851711f0b1dd0c83c518f867' "$build_workflow"
grep -Fx '  MELANGE_VERSION: 0.56.5' "$build_workflow"
grep -Fx '  MELANGE_SHA256: 40e17d259c9fd7bce8e000a59239d7b9ebf13971117334ad117ae6eefd98f92b' "$build_workflow"
grep -Fx '  GRYPE_VERSION: 0.116.1' "$build_workflow"
grep -Fx '  GRYPE_SHA256: 0122df7b655981abe547ad3d2190d65551dac6a2bfc80b4dc2a989b5d0587458' "$build_workflow"
grep -Fx '  TRIVY_VERSION: 0.73.0' "$build_workflow"
grep -Fx '  TRIVY_SHA256: 2edd39da482bb4e9831962487b68f68e3928ec3137794757f54d00383d79547b' "$build_workflow"
[[ $(grep -Fc '          MELANGE_VERSION: 0.56.5' "$apk_workflow") -eq 3 ]]
grep -Fx '      melange_sha256=40e17d259c9fd7bce8e000a59239d7b9ebf13971117334ad117ae6eefd98f92b' "$script"
grep -Fx '      melange_sha256=3b8565a5d924df0a7a7e61895f62972017f5613bead2d45218e0e4d47f7601c1' "$script"
