#!/bin/bash
set -euo pipefail

script=$(cd "$(dirname "$0")" && pwd)/install_image_tools.sh
apk_exit=$(awk '/track" == apk/ {getline; print NR; exit}' "$script")
grype_install=$(awk '/sudo install \/tmp\/grype \/usr\/local\/bin\/grype/ {print NR}' "$script")
monitor_exit=$(awk '/track" == monitor/ {getline; print NR; exit}' "$script")
wolfi_exit=$(awk '/track" == wolfi/ {wolfi=1} wolfi && /^  exit$/ {print NR; exit}' "$script")
[[ -n "$apk_exit" && -n "$grype_install" && -n "$monitor_exit" && -n "$wolfi_exit" ]]
[[ "$apk_exit" -lt "$grype_install" && "$grype_install" -lt "$monitor_exit" && "$monitor_exit" -lt "$wolfi_exit" ]]
