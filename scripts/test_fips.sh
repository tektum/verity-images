#!/bin/sh
set -eu

mode=${1:?usage: test_fips.sh provider IMAGE | compatibility PLAIN FIPS}

case "$mode" in
  provider)
    image=${2:?usage: test_fips.sh provider IMAGE}
    run_go() {
      runtime=${1:?runtime directory is required}
      shift
      docker run --rm --read-only \
        --tmpfs "$runtime:rw,noexec,nosuid,nodev,mode=1777" \
        -e "OPENSSL_FIPS_RUNTIME_DIR=$runtime" \
        "$image" "$@"
    }
    run_provider() {
      runtime=${1:?runtime directory is required}
      shift
      docker run --rm --read-only \
        --tmpfs "$runtime:rw,noexec,nosuid,nodev,mode=1777" \
        -e "OPENSSL_FIPS_RUNTIME_DIR=$runtime" \
        --entrypoint /usr/bin/openssl-fips-activate "$image" "$@"
    }
    run_go /run/openssl-fips-default version | grep -q '^go version '
    [ "$(run_go /run/openssl-fips-arguments env GOFIPS140)" = v1.0.0 ]
    [ "$(run_provider /run/openssl-fips-first /usr/bin/printf '%s|%s' 'a b' c)" = 'a b|c' ]
    providers=$(run_provider /run/openssl-fips-second openssl list -providers -verbose)
    printf '%s\n' "$providers" | grep -q 'version: 3.1.2'
    printf '%s\n' "$providers" | grep -q 'status: active'
    printf '' | run_provider /run/openssl-fips-first openssl dgst -sha256 >/dev/null
    if printf '' | run_provider /run/openssl-fips-second openssl dgst -md5 >/dev/null 2>&1; then
      exit 1
    fi
    work=$(mktemp -d)
    container=$(docker create "$image")
    trap 'docker rm -f "$container" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT INT TERM
    docker cp "$container:/usr/lib/ossl-modules/fips.so" "$work/fips.so"
    docker rm "$container" >/dev/null
    printf 'tampered' >>"$work/fips.so"
    if docker run --rm --read-only \
      --tmpfs /run/openssl-fips-tampered:rw,noexec,nosuid,nodev,mode=1777 \
      -e OPENSSL_FIPS_RUNTIME_DIR=/run/openssl-fips-tampered \
      -v "$work/fips.so:/usr/lib/ossl-modules/fips.so:ro" \
      "$image" version >/dev/null 2>&1; then
      exit 1
    fi
    docker run --rm --read-only --user 65532 \
      --tmpfs /run/openssl-fips-nonroot:rw,noexec,nosuid,nodev,mode=1777 \
      -e OPENSSL_FIPS_RUNTIME_DIR=/run/openssl-fips-nonroot \
      "$image" version >/dev/null
    if docker run --rm --read-only --user 65532 \
      --tmpfs /run/openssl-fips-denied:rw,noexec,nosuid,nodev,mode=0500 \
      -e OPENSSL_FIPS_RUNTIME_DIR=/run/openssl-fips-denied \
      "$image" version >/dev/null 2>&1; then
      exit 1
    fi
    trap - EXIT INT TERM
    rm -rf "$work"
    ;;
  compatibility)
    plain=${2:?usage: test_fips.sh compatibility PLAIN FIPS}
    fips=${3:?usage: test_fips.sh compatibility PLAIN FIPS}
    format='{{json .Config.User}}|{{json .Config.Cmd}}|{{json .Config.WorkingDir}}|{{json .Config.ExposedPorts}}|{{json .Config.Volumes}}'
    [ "$(docker image inspect --format "$format" "$plain")" = \
      "$(docker image inspect --format "$format" "$fips")" ]
    ;;
  *)
    printf 'usage: test_fips.sh provider IMAGE | compatibility PLAIN FIPS\n' >&2
    exit 2
    ;;
esac
