#!/bin/bash
set -euo pipefail

script=$(cd "$(dirname "$0")" && pwd)/install_image_tools.sh
grype_install=$(awk '/sudo install \/tmp\/grype \/usr\/local\/bin\/grype/ {print NR}' "$script")
wolfi_exit=$(awk '/^  exit$/ {print NR; exit}' "$script")
[[ -n "$grype_install" && -n "$wolfi_exit" && "$grype_install" -lt "$wolfi_exit" ]]
