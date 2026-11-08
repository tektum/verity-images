#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

test "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532 ||
  fail 'image must run as UID 65532'
test "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/clickhouse-operator"]' ||
  fail 'unexpected entrypoint'

docker run --rm "$image" -version 2>&1 | grep -E '^v?0\.27\.[0-9]+$' >/dev/null ||
  fail 'unexpected operator version'

docker run --rm "$image" -help >"$tmp/help.log" 2>&1 || true
for flag in -config -kubeconfig -metrics-endpoint -metrics-path -version; do
  grep -E "^[[:space:]]+$flag( |\$)" "$tmp/help.log" >/dev/null ||
    fail "expected flag $flag missing from -help"
done

# Outside a cluster and without a kubeconfig the operator must refuse to
# start with its documented error instead of crashing in flag or config parsing.
if docker run --rm "$image" >"$tmp/start.log" 2>&1; then
  fail 'operator unexpectedly started without a kubeconfig'
fi
grep -F 'Unable to build kubeconf' "$tmp/start.log" >/dev/null ||
  { cat "$tmp/start.log" >&2; fail 'missing no-kubeconfig error'; }

if docker run --rm "$image" -no-such-flag >"$tmp/flag.log" 2>&1; then
  fail 'unknown flag unexpectedly succeeded'
fi
grep -F 'flag provided but not defined: -no-such-flag' "$tmp/flag.log" >/dev/null ||
  fail 'unknown flag error missing'

printf 'SMOKE PASS image=%s\n' "$image"
