#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 || -z "$1" || -z "$2" ]]; then
  printf 'usage: apk-package-version.sh INPUT_DIR PACKAGE\n' >&2
  exit 2
fi
input=$1
package=$2
version=

for architecture in x86_64 aarch64; do
  metadata="$input/apk-build-$package-$architecture/metadata.json"
  if [[ ! -f "$metadata" ]]; then
    printf 'missing build metadata: %s\n' "$metadata" >&2
    exit 2
  fi
  architecture_version=$(jq -er '.identity.version' "$metadata")
  if [[ "$(jq -er '.identity.name' "$metadata")" != "$package" || \
    "$(jq -er '.architecture' "$metadata")" != "$architecture" || \
    "$(jq -er '.recipe.path' "$metadata")" != "packages/$package/melange.yaml" || \
    ! "$architecture_version" =~ ^[A-Za-z0-9][A-Za-z0-9._+~:-]*-r[0-9]+$ ]]; then
    printf 'invalid build metadata: %s\n' "$metadata" >&2
    exit 2
  fi
  if [[ -n "$version" && "$version" != "$architecture_version" ]]; then
    printf 'build metadata versions disagree for %s\n' "$package" >&2
    exit 2
  fi
  version=$architecture_version
done

printf '%s\n' "$version"
