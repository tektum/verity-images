#!/bin/bash
set -euo pipefail

repository=${1:?usage: verify_apk_repository.sh REPOSITORY KEY}
key=${2:?usage: verify_apk_repository.sh REPOSITORY KEY}
resolved_key=$(realpath "$key")
key_name=$(basename "$resolved_key")

docker run --rm \
  -v "$(realpath "$repository"):/repository:ro" \
  -v "$(dirname "$resolved_key"):/keys:ro" \
  cgr.dev/chainguard/wolfi-base@sha256:003627df3c1e1bba0c4116afcddb314aca9594ee2328c7e876a8081a6c988b2e \
  sh -ec '
    keys=$(mktemp -d)
    cp "/keys/$1" "$keys/$1"
    apk --keys-dir "$keys" verify \
      /repository/x86_64/APKINDEX.tar.gz \
      /repository/x86_64/openssl-fips-provider-*.apk \
      /repository/aarch64/APKINDEX.tar.gz \
      /repository/aarch64/openssl-fips-provider-*.apk
  ' sh "$key_name"
