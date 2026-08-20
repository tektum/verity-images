#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
: "${IMAGE_VERSION:?IMAGE_VERSION is required}"
work=$(mktemp -d)

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/contour"]' ] \
  || fail 'unexpected image entrypoint'
[ "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["serve"]' ] \
  || fail 'unexpected image command'
[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] \
  || fail 'unexpected OCI user'

docker run --rm --network none "$image" version 2>&1 \
  | grep -F "v${IMAGE_VERSION}" >/dev/null \
  || fail 'contour version check failed'
docker run --rm --network none "$image" serve --help >/dev/null \
  || fail 'contour serve help failed without cluster credentials'

printf '%s\n' 'accesslog-format: json' >"$work/valid.yaml"
chmod 644 "$work/valid.yaml"
if valid_output=$(docker run --rm --network none \
  -v "$work/valid.yaml:/tmp/config.yaml:ro" \
  "$image" serve --config-path /tmp/config.yaml 2>&1); then
  fail 'contour serve unexpectedly started without cluster credentials'
fi
case "$valid_output" in
  *'unable to initialize Server dependencies required to start Contour'*) ;;
  *)
    printf '%s\n' "$valid_output" >&2
    fail 'valid configuration did not reach cluster initialization'
    ;;
esac

printf '%s\n' 'accesslog-format: definitely-invalid' >"$work/invalid.yaml"
chmod 644 "$work/invalid.yaml"
if invalid_output=$(docker run --rm --network none \
  -v "$work/invalid.yaml:/tmp/config.yaml:ro" \
  "$image" serve --config-path /tmp/config.yaml 2>&1); then
  fail 'invalid Contour configuration unexpectedly succeeded'
fi
case "$invalid_output" in
  *'invalid Contour configuration'*) ;;
  *)
    printf '%s\n' "$invalid_output" >&2
    fail 'invalid configuration diagnostic missing'
    ;;
esac

printf 'SMOKE PASS image=%s\n' "$image"
