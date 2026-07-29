#!/bin/bash
set -euo pipefail

context=${1:?usage: build_candidate.sh CONTEXT NAME TRACK VERSION}
name=${2:?usage: build_candidate.sh CONTEXT NAME TRACK VERSION}
track=${3:?usage: build_candidate.sh CONTEXT NAME TRACK VERSION}
version=${4:?usage: build_candidate.sh CONTEXT NAME TRACK VERSION}
output="dist/${name}"
candidate="local/verity-${name}:${GITHUB_SHA}"

mkdir -p "${output}/sbom"

if [[ "$track" == wolfi ]]; then
  apko show-config "${context}/apko.yaml" >/dev/null
  apko lock "${context}/apko.yaml" --arch amd64,arm64 --output "${output}/apko.lock.json"
  apko build "${context}/apko.yaml" "$candidate" "${output}/image.tar" \
    --arch amd64,arm64 --lockfile "${output}/apko.lock.json" --sbom-path "${output}/sbom"
  docker load < "${output}/image.tar"
  printf '%s\n' "${output}/apko.lock.json" > "${output}/evidence-path"
  exit
fi

image=$(awk '$1 == "image:" {print $2}' "${context}/source.yaml")
pinned=$(awk '$1 == "digest:" {print $2}' "${context}/source.yaml")
digest=$pinned
if [[ "${REFRESH_SOURCE:-false}" == true ]]; then
  digest="sha256:$(docker buildx imagetools inspect "$image" --raw | sha256sum | cut -d' ' -f1)"
fi

jq -n --arg image "$image" --arg pinned "$pinned" --arg resolved "$digest" \
  --arg version "$version" \
  '{image:$image,pinnedDigest:$pinned,resolvedDigest:$resolved,version:$version}' \
  > "${output}/source-resolved.json"

repository=${image%:*}
index=$(docker buildx imagetools inspect "${repository}@${digest}" --raw)
for arch in amd64 arm64; do
  upstream="${candidate}-upstream-${arch}"
  patched="${candidate}-${arch}"
  report="${output}/trivy-${arch}.json"
  library_report="${output}/trivy-library-${arch}.json"
  child=$(jq -r --arg arch "$arch" '
    .manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest' <<<"$index")
  [[ "$child" == sha256:* ]]
  docker pull "${repository}@${child}"
  docker tag "${repository}@${child}" "$upstream"
  trivy image --image-src docker --scanners vuln --pkg-types os --ignore-unfixed \
    --format json --output "$report" "$upstream"
  updates=$(jq '[.Results[]?.Vulnerabilities[]?] | length' "$report")
  if [[ "$updates" -eq 0 ]]; then
    docker tag "$upstream" "$patched"
  else
    copa patch --image "$upstream" --report "$report" --tag "${GITHUB_SHA}-${arch}" \
      --addr docker:// --timeout 20m --progress plain
    source_repository=${upstream%:*}
    docker tag "${source_repository}:${GITHUB_SHA}-${arch}" "$patched"
  fi
  trivy image --image-src docker --scanners vuln --pkg-types library --ignore-unfixed \
    --format json --output "$library_report" "$patched"
  library_updates=$(jq '[.Results[]?.Vulnerabilities[]?] | length' "$library_report")
  if [[ "$library_updates" -ne 0 ]]; then
    library_source="${candidate}-library-${arch}"
    docker tag "$patched" "$library_source"
    COPA_EXPERIMENTAL=1 copa patch --image "$library_source" --report "$library_report" \
      --tag "${GITHUB_SHA}-library-${arch}" --pkg-types library --library-patch-level patch \
      --addr docker:// --timeout 20m --progress plain
    library_repository=${library_source%:*}
    docker tag "${library_repository}:${GITHUB_SHA}-library-${arch}" "$patched"
  fi
  syft "docker:${patched}" -o "spdx-json=${output}/sbom/sbom-${arch}.spdx.json"
done

cp "${output}/sbom/sbom-amd64.spdx.json" "${output}/sbom/sbom-index.spdx.json"
printf '%s\n' "${output}/source-resolved.json" > "${output}/evidence-path"
