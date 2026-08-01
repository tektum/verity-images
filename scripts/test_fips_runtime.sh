#!/bin/bash
set -euo pipefail

repository=${1:?usage: test_fips_runtime.sh REPOSITORY KEY}
key=${2:?usage: test_fips_runtime.sh REPOSITORY KEY}

docker run --rm --platform linux/amd64 \
  -v "$(realpath "$repository"):/repository:ro" \
  -v "$(realpath "$key"):$(realpath "$key"):ro" \
  cgr.dev/chainguard/wolfi-base:latest \
  sh -ec '
    keys=$(mktemp -d)
    cp "$1" "$keys/$(basename "$1")"
    apk add --no-cache openssl
    apk --keys-dir "$keys" verify /repository/APKINDEX.tar.gz /repository/openssl-fips-provider-*.apk
    apk --keys-dir "$keys" add --no-network /repository/openssl-fips-provider-*.apk
    install -d -m 700 /run/openssl-fips
    for cwd in / /tmp; do
      (
        cd "$cwd"
        OPENSSL_FIPS_RUNTIME_DIR=/run/openssl-fips \
          openssl-fips-activate openssl list -provider fips -providers
      )
    done
    test -f /run/openssl-fips/openssl.cnf
    test -f /run/openssl-fips/fipsmodule.cnf
  ' sh "$(realpath "$key")"
