#!/bin/bash
set -euo pipefail

target=${1:?usage: attest_sboms.sh TARGET DIGEST SBOM_DIRECTORY}
digest=${2:?usage: attest_sboms.sh TARGET DIGEST SBOM_DIRECTORY}
directory=${3:?usage: attest_sboms.sh TARGET DIGEST SBOM_DIRECTORY}
declare -A sboms=()
for sbom in "$directory"/sbom-*.spdx.json; do
  case ${sbom##*/} in
    sbom-index.spdx.json) continue ;;
    sbom-amd64.spdx.json | sbom-x86_64.spdx.json) arch=amd64 ;;
    sbom-arm64.spdx.json | sbom-aarch64.spdx.json) arch=arm64 ;;
    *) printf 'unsupported SBOM: %s\n' "$sbom" >&2; exit 2 ;;
  esac
  [[ -z ${sboms[$arch]:-} ]]
  sboms[$arch]=$sbom
done
[[ ${#sboms[@]} -eq 2 ]]

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cosign sign --yes "${target}@${digest}"
for arch in amd64 arm64; do
  predicate=$work/$arch.spdx.json
  jq --arg arch "$arch" '.name += "-verity-platform-" + $arch' \
    "${sboms[$arch]}" > "$predicate"
  cosign attest --yes --type spdxjson --predicate "$predicate" "${target}@${digest}"
  jq --arg arch "$arch" '{bomFormat:"CycloneDX",specVersion:"1.5",name:(.name + "-verity-platform-" + $arch),components:[.packages[] | {name,version:(.versionInfo),purl:(.externalRefs[] | select(.referenceType == "purl") | .referenceLocator)}]}' \
    "${sboms[$arch]}" > "$work/$arch.cyclonedx.json"
  cosign attest --yes --type cyclonedx --predicate "$work/$arch.cyclonedx.json" "${target}@${digest}"
done
