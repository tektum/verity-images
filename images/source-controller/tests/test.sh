#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65534 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/manager"]' ] || fail 'unexpected OCI entrypoint'

help_status=0
help_output=$(docker run --rm --network none "$image" --help 2>&1) || help_status=$?
case "$help_status" in
  0|2) ;;
  *) fail '/manager help returned an unexpected status' ;;
esac
case "$help_output" in
  *"Usage of /manager:"*) ;;
  *) fail '/manager help output missing' ;;
esac

for flag in webhook config; do
  status=0
  output=$(docker run --rm --network none "$image" "--$flag=invalid" 2>&1) || status=$?
  [ "$status" -eq 2 ] || fail "unsupported --$flag returned an unexpected status"
  case "$output" in
    *"unknown flag: --$flag"*) ;;
    *)
      printf '%s\n' "$output" >&2
      fail "unsupported --$flag diagnostic missing"
      ;;
  esac
done

printf 'SMOKE PASS image=%s\n' "$image"
