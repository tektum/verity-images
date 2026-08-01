#!/bin/sh
set -eu

mode=${1:?usage: test_fips.sh provider IMAGE | compatibility PLAIN FIPS}

case "$mode" in
  provider)
    image=${2:?usage: test_fips.sh provider IMAGE}
    docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
      grep -qx 'OPENSSL_CONF=/etc/ssl/openssl-fips.cnf'
    docker run --rm --entrypoint openssl "$image" fipsinstall -verify \
      -module /usr/lib/ossl-modules/fips.so -in /etc/ssl/fipsmodule.cnf
    providers=$(docker run --rm --entrypoint openssl "$image" list -providers -verbose)
    printf '%s\n' "$providers" | grep -q 'version: 3.1.2'
    printf '%s\n' "$providers" | grep -q 'status: active'
    printf '' | docker run --rm -i --entrypoint openssl "$image" dgst -sha256 >/dev/null
    if printf '' | docker run --rm -i --entrypoint openssl "$image" dgst -md5 >/dev/null 2>&1; then
      exit 1
    fi
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
