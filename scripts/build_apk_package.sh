#!/bin/bash
set -euo pipefail

architecture=${1:?usage: build_apk_package.sh ARCHITECTURE}

case "$architecture" in
  x86_64) expected_machine=x86_64 ;;
  aarch64) expected_machine=aarch64 ;;
  *)
    printf 'unsupported architecture: %s\n' "$architecture" >&2
    exit 2
    ;;
esac

[[ "$(uname -m)" == "$expected_machine" ]]
melange build packages/openssl-fips-provider/melange.yaml --arch "$architecture" \
  --runner docker --out-dir out/packages --cache-dir out/cache
mapfile -t packages < <(find out/packages -type f -name 'openssl-fips-provider-3.1.2-r2.apk' -print | sort)
[[ "${#packages[@]}" -eq 1 ]]
mkdir artifact
cp "${packages[0]}" artifact/openssl-fips-provider-3.1.2-r2.apk
sha256sum artifact/openssl-fips-provider-3.1.2-r2.apk > artifact/SHA256SUMS

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM
mkdir "$work_dir/repository"
melange keygen "$work_dir/test.rsa"
cp artifact/openssl-fips-provider-3.1.2-r2.apk "$work_dir/repository/"
melange sign --signing-key "$work_dir/test.rsa" "$work_dir/repository/openssl-fips-provider-3.1.2-r2.apk"
melange index --arch "$architecture" --signing-key "$work_dir/test.rsa" \
  --output "$work_dir/repository/APKINDEX.tar.gz" \
  "$work_dir/repository/openssl-fips-provider-3.1.2-r2.apk"
scripts/test_fips_runtime.sh "$work_dir/repository" "$work_dir/test.rsa.pub" "$architecture"
