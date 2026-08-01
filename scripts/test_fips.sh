#!/bin/sh
set -eu

mode=${1:?usage: test_fips.sh provider IMAGE | compatibility PLAIN FIPS}

case "$mode" in
  provider)
    image=${2:?usage: test_fips.sh provider IMAGE}
    runtime=/run/openssl-fips
    run_provider() {
      docker run --rm --read-only \
        --tmpfs "$runtime:rw,noexec,nosuid,nodev,mode=1777" \
        -e "OPENSSL_FIPS_RUNTIME_DIR=$runtime" \
        --entrypoint /usr/bin/openssl-fips-activate "$image" "$@"
    }
    [ "$(run_provider /usr/bin/printf '%s|%s' 'a b' c)" = 'a b|c' ]
    providers=$(run_provider openssl list -providers -verbose)
    printf '%s\n' "$providers" | grep -q 'version: 3.1.2'
    printf '%s\n' "$providers" | grep -q 'status: active'
    printf '' | run_provider openssl dgst -sha256 >/dev/null
    if printf '' | run_provider openssl dgst -md5 >/dev/null 2>&1; then
      exit 1
    fi
    work=$(mktemp -d)
    container=$(docker create "$image")
    trap 'docker rm -f "$container" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT INT TERM
    docker cp "$container:/usr/lib/ossl-modules/fips.so" "$work/fips.so"
    docker rm "$container" >/dev/null
    printf 'tampered' >>"$work/fips.so"
    if docker run --rm --read-only \
      --tmpfs "$runtime:rw,noexec,nosuid,nodev,mode=1777" \
      -e "OPENSSL_FIPS_RUNTIME_DIR=$runtime" \
      -v "$work/fips.so:/usr/lib/ossl-modules/fips.so:ro" \
      --entrypoint /usr/bin/openssl-fips-activate "$image" openssl version >/dev/null 2>&1; then
      exit 1
    fi
    trap - EXIT INT TERM
    rm -rf "$work"
    ;;
  compatibility)
    plain=${2:?usage: test_fips.sh compatibility PLAIN FIPS}
    fips=${3:?usage: test_fips.sh compatibility PLAIN FIPS}
    format='{{json .Config.User}}|{{json .Config.Entrypoint}}|{{json .Config.Cmd}}|{{json .Config.WorkingDir}}|{{json .Config.ExposedPorts}}|{{json .Config.Volumes}}'
    [ "$(docker image inspect --format "$format" "$plain")" = \
      "$(docker image inspect --format "$format" "$fips")" ]
    ;;
  *)
    printf 'usage: test_fips.sh provider IMAGE | compatibility PLAIN FIPS\n' >&2
    exit 2
    ;;
esac
