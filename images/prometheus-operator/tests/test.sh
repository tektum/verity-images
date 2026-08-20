#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
: "${IMAGE_VERSION:?IMAGE_VERSION is required}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65534 ] ||
  fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/bin/operator"]' ] ||
  fail 'unexpected OCI entrypoint'
case $(docker image inspect -f '{{json .Config.Cmd}}' "$image") in
  null|'[]') ;;
  *) fail 'unexpected OCI command' ;;
esac

run() {
  docker run --rm --network none --read-only --cap-drop ALL \
    --security-opt no-new-privileges --cpus 1 --memory 512m --pids-limit 128 \
    "$image" "$@"
}

run --version >"$work/version"
grep -F "prometheus-operator, version ${IMAGE_VERSION}" "$work/version" >/dev/null ||
  fail 'unexpected operator version'

run crds >"$work/crds"
grep -F 'kind: CustomResourceDefinition' "$work/crds" >/dev/null ||
  fail 'operator did not render CRDs'
grep -F 'monitoring.coreos.com' "$work/crds" >/dev/null ||
  fail 'operator CRDs use an unexpected API group'

if run --definitely-invalid >"$work/invalid" 2>&1; then
  fail 'invalid flag unexpectedly succeeded'
fi
grep -F 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'invalid flag diagnostic missing'

printf 'SMOKE PASS image=%s\n' "$image"
