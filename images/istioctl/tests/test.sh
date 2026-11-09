#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
recipe="$(dirname "$0")/../melange.yaml"
version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' "$recipe")
commit=$(sed -n 's/^[[:space:]]*expected-commit: \([0-9a-f]\{40\}\)$/\1/p' "$recipe")
[ -n "$version" ] || { printf 'package version not found\n' >&2; exit 1; }
[ -n "$commit" ] || { printf 'source commit not found\n' >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

run() {
  docker run --rm --network none --read-only --cpus 2 --memory 512m --pids-limit 256 "$image" "$@"
}

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 1000 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ] \
  || fail 'unexpected working directory'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/istioctl"]' ] \
  || fail 'unexpected entrypoint'
case $(docker image inspect -f '{{json .Config.Cmd}}' "$image") in null|'[]') ;; *) fail 'unexpected image command' ;; esac

run version --remote=false >"$work/version" 2>&1 || fail 'version --remote=false failed'
grep -Fx "client version: ${version}" "$work/version" >/dev/null \
  || fail "unexpected version output: $(cat "$work/version")"

run version --remote=false -o json >"$work/version.json" 2>&1 || fail 'version -o json failed'
grep -F "\"revision\": \"${commit}\"" "$work/version.json" >/dev/null \
  || fail "source commit is not embedded: $(cat "$work/version.json")"

run manifest generate >"$work/default.yaml" 2>"$work/default.err" \
  || fail "manifest generate failed: $(cat "$work/default.err")"
grep -Fx 'kind: CustomResourceDefinition' "$work/default.yaml" >/dev/null \
  || fail 'default manifest is missing CRDs'
grep -Fx 'kind: Deployment' "$work/default.yaml" >/dev/null \
  || fail 'default manifest is missing deployments'
grep -E "image: registry\.istio\.io/release/pilot:${version}$" "$work/default.yaml" >/dev/null \
  || fail 'default manifest does not pin istiod to the release hub and version'
grep -F 'name: istio-ingressgateway' "$work/default.yaml" >/dev/null \
  || fail 'default profile is missing the ingress gateway'

run manifest generate --set profile=minimal >"$work/minimal.yaml" 2>"$work/minimal.err" \
  || fail "minimal manifest generate failed: $(cat "$work/minimal.err")"
if grep -F 'name: istio-ingressgateway' "$work/minimal.yaml" >/dev/null; then
  fail 'minimal profile unexpectedly renders the ingress gateway'
fi

if run manifest generate --set profile=not-a-profile >"$work/profile" 2>&1; then
  fail 'unknown profile unexpectedly succeeded'
fi
grep -F 'profile "not-a-profile" not found' "$work/profile" >/dev/null \
  || fail "unknown profile diagnostic missing: $(cat "$work/profile")"

if run --not-a-real-flag >"$work/flag" 2>&1; then
  fail 'unknown flag unexpectedly succeeded'
fi
grep -F 'unknown flag: --not-a-real-flag' "$work/flag" >/dev/null \
  || fail "unknown flag diagnostic missing: $(cat "$work/flag")"

printf 'SMOKE PASS image=%s\n' "$image"
