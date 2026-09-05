#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65534 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/manager"]' ] || fail 'unexpected OCI entrypoint'
case $(docker image inspect -f '{{json .Config.Cmd}}' "$image") in
  null|'[]') ;;
  *) fail 'unexpected OCI command' ;;
esac

help_output=$(docker run --rm --network none --read-only --user 65534 \
  --cpus 4 --memory 1g --pids-limit 256 "$image" --help 2>&1) \
  || fail '/manager help failed'
case "$help_output" in
  *"Usage of /manager:"*) ;;
  *) fail '/manager help output missing' ;;
esac
case "$help_output" in
  *"--default-service-account string"*) ;;
  *) fail '/manager 1.9 options missing' ;;
esac

if output=$(docker run --rm --network none --read-only --user 65534 \
  --cpus 4 --memory 1g --pids-limit 256 -e KUBECONFIG=/tmp/missing \
  "$image" 2>&1); then
  fail 'missing Kubernetes credentials unexpectedly succeeded'
fi
case "$output" in
  *"unable to get kubeconfig"*) ;;
  *)
    printf '%s\n' "$output" >&2
    fail 'missing Kubernetes credentials diagnostic missing'
    ;;
esac

for flag in webhook config; do
  status=0
  output=$(docker run --rm --network none --read-only --user 65534 \
    --cpus 4 --memory 1g --pids-limit 256 "$image" "--$flag=invalid" 2>&1) \
    || status=$?
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
