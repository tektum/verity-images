#!/bin/bash
set -euo pipefail

repository=${1:?usage: test_fips_runtime.sh REPOSITORY KEY ARCHITECTURE}
key=${2:?usage: test_fips_runtime.sh REPOSITORY KEY ARCHITECTURE}
architecture=${3:?usage: test_fips_runtime.sh REPOSITORY KEY ARCHITECTURE}

case "$architecture" in
  x86_64) platform=linux/amd64 ;;
  aarch64) platform=linux/arm64 ;;
  *)
    printf 'unsupported architecture: %s\n' "$architecture" >&2
    exit 2
    ;;
esac

docker run --rm --platform "$platform" \
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
          openssl-fips-activate sh -ec '\''
            openssl list -provider fips -providers | grep -F "version: 3.1.2"
            openssl dgst -sha256 /dev/null >/dev/null
            ! openssl dgst -md5 /dev/null >/dev/null 2>&1
            test "$1" = argv-preserved
          '\'' sh argv-preserved
      )
    done
    test -f /run/openssl-fips/openssl.cnf
    test -f /run/openssl-fips/fipsmodule.cnf
    grep -Fxq ".include /run/openssl-fips/fipsmodule.cnf" /run/openssl-fips/openssl.cnf
    grep -Fxq "base = base_sect" /run/openssl-fips/openssl.cnf
    grep -Fxq "default_properties = fips=yes" /run/openssl-fips/openssl.cnf
    cp /usr/lib/ossl-modules/fips.so /tmp/fips.so
    trap "mv /tmp/fips.so /usr/lib/ossl-modules/fips.so" EXIT
    printf x | dd of=/usr/lib/ossl-modules/fips.so bs=1 seek=0 conv=notrunc status=none
    ! OPENSSL_FIPS_RUNTIME_DIR=/run/openssl-fips openssl-fips-activate true
    mv /tmp/fips.so /usr/lib/ossl-modules/fips.so
    trap - EXIT
    adduser -D fips-test
    install -d -m 500 /run/openssl-fips-denied
    ! su fips-test -s /bin/sh -c "OPENSSL_FIPS_RUNTIME_DIR=/run/openssl-fips-denied openssl-fips-activate true"
  ' sh "$(realpath "$key")"
