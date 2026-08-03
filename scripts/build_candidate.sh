#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
context=${1:?usage: build_candidate.sh CONTEXT BUILD_NAME FLAVOR TRACK VERSION}
build_name=${2:?usage: build_candidate.sh CONTEXT BUILD_NAME FLAVOR TRACK VERSION}
flavor=${3:?usage: build_candidate.sh CONTEXT BUILD_NAME FLAVOR TRACK VERSION}
track=${4:?usage: build_candidate.sh CONTEXT BUILD_NAME FLAVOR TRACK VERSION}
version=${5:?usage: build_candidate.sh CONTEXT BUILD_NAME FLAVOR TRACK VERSION}
output="dist/${build_name}"
candidate="local/verity-${build_name}:${GITHUB_SHA}"

mkdir -p "${output}/sbom"

if [[ "$track" == wolfi ]]; then
  config="${context}/apko.yaml"
  lockfile="${context}/apko.lock.json"
  if [[ "$flavor" != plain && -f "${context}/${flavor}.apko.yaml" ]]; then
    config="${context}/${flavor}.apko.yaml"
    lockfile="${context}/${flavor}.apko.lock.json"
    [[ -f "${context}/${flavor}-wrapper.apko.yaml" ]] && config="${context}/${flavor}-wrapper.apko.yaml"
  fi
  template=$config
  [[ -f "$template" ]]
  recipe="${context}/melange.yaml"
  [[ -f "${context}/${flavor}.melange.yaml" ]] && recipe="${context}/${flavor}.melange.yaml"
  if [[ -f "$recipe" ]]; then
    key_dir=$(mktemp -d)
    key="$key_dir/melange.rsa"
    config=$(mktemp)
    trap 'rm -rf "$key_dir"; rm -f "$config"' EXIT
    mkdir -p "${output}/packages"
    melange keygen "$key"
    melange_args=(--runner docker --signing-key "$key" \
      --out-dir "${output}/packages" --generate-provenance)
    for arch in amd64 arm64; do
      if [[ -f "${context}/${flavor}.env" ]]; then
        melange build "$recipe" --arch "$arch" "${melange_args[@]}" \
          --env-file "${context}/${flavor}.env"
      else
        melange build "$recipe" --arch "$arch" "${melange_args[@]}"
      fi
    done
    godebug=fips140=off
    [[ "$flavor" == fips ]] && godebug=fips140=only
    sed -e "s|@LOCAL_REPOSITORY@|$(realpath "${output}/packages")|" \
      -e "s|@LOCAL_KEY@|$key.pub|" -e "s|@GODEBUG@|$godebug|" \
      -e "s|@REPOSITORY_KEY@|$root/packages/keys/verity-apk-2026.rsa.pub|" \
      "$template" > "$config"
    apko show-config "$config" >/dev/null
    apko lock "$config" --arch amd64,arm64 --output "${output}/apko.lock.json"
  else
    apko show-config "$config" >/dev/null
    cp "$lockfile" "${output}/apko.lock.json"
  fi
  apko build "$config" "$candidate" "${output}/image.tar" \
    --arch amd64,arm64 --lockfile "${output}/apko.lock.json" --sbom-path "${output}/sbom"
  docker load < "${output}/image.tar"
  printf '%s\n' "${output}/apko.lock.json" > "${output}/evidence-path"
  exit
fi

image=$(awk '$1 == "image:" {print $2}' "${context}/source.yaml")
pinned=$(awk '$1 == "digest:" {print $2}' "${context}/source.yaml")
npm_version=$(awk '$1 == "npm-version:" {print $2}' "${context}/source.yaml")
digest=$pinned

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
  if [[ -n "$npm_version" ]]; then
    npm_patched="${candidate}-npm-${arch}"
    docker build --build-arg BASE="$patched" --build-arg NPM_VERSION="$npm_version" \
      --tag "$npm_patched" - <<'EOF'
ARG BASE
FROM ${BASE}
ARG NPM_VERSION
RUN npm install --global "npm@${NPM_VERSION}" --ignore-scripts
EOF
    docker tag "$npm_patched" "$patched"
  fi
  if grep -Eq '^[[:space:]]*gosu-' "${context}/source.yaml"; then
    gosu_patched="${candidate}-gosu-${arch}"
    scripts/replace_gosu.sh "${context}/source.yaml" "$arch" "$patched" "$gosu_patched"
    docker tag "$gosu_patched" "$patched"
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
