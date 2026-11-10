#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
work=$(mktemp -d)

cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

run() {
  docker run --rm --network none --read-only --cpus 2 --memory 512m --pids-limit 256 "$@"
}

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/tkn"]' ] ||
  fail 'unexpected entrypoint'
case $(docker image inspect -f '{{json .Config.Cmd}}' "$image") in
  null | '[]') ;;
  *) fail 'unexpected image command' ;;
esac

# stdout only: docker prints a platform mismatch warning on stderr for emulated arm64 runs.
version_output=$(run "$image" version --component client) || fail 'tkn version failed'
[ "$version_output" = "$expected_version" ] || fail "unexpected version output: $version_output"

run "$image" --help >"$work/help" 2>&1 || fail 'tkn --help failed'
for want in 'Usage:' 'pipeline' 'taskrun' 'pipelinerun'; do
  grep -F -- "$want" "$work/help" >/dev/null || fail "tkn help is missing $want"
done

if run "$image" --definitely-invalid >"$work/invalid" 2>&1; then
  fail 'unknown flag unexpectedly succeeded'
fi
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'unknown flag diagnostic is missing'

if run "$image" definitely-invalid >"$work/command" 2>&1; then
  fail 'unknown command unexpectedly succeeded'
fi
grep -F "command tkn definitely-invalid doesn't exist" "$work/command" >/dev/null ||
  fail 'unknown command diagnostic is missing'

if run "$image" pipeline list --kubeconfig /definitely-missing >"$work/kubeconfig" 2>&1; then
  fail 'missing kubeconfig unexpectedly succeeded'
fi
grep -F 'no such file or directory' "$work/kubeconfig" >/dev/null ||
  fail 'missing kubeconfig diagnostic is missing'

printf 'SMOKE PASS image=%s\n' "$image"
