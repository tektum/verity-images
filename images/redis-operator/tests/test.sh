#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  for log in "$work"/*.log; do
    [ ! -f "$log" ] || { printf '== %s\n' "$log" >&2; cat "$log" >&2; }
  done
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/operator"]' ] || fail 'unexpected entrypoint'
[ "$(docker image inspect -f '{{json .Config.Cmd}}' "$image")" = '["manager"]' ] || fail 'unexpected command'
env=$(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$image")
printf '%s\n' "$env" | grep -qx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' || fail 'missing CA configuration'

docker run --rm --network none "$image" manager --help >"$work/help.log" 2>&1 || fail 'operator help failed'
grep -q -- 'leader-elect' "$work/help.log" || fail 'operator help output is invalid'
docker run --rm --network none --entrypoint /operator "$image" manager --help >/dev/null 2>&1 || fail '/operator compatibility path is not executable'

# Without a cluster the manager must reach Kubernetes client configuration and fail closed.
if docker run --rm --network none "$image" >"$work/startup.log" 2>&1; then
  fail 'manager unexpectedly started without a cluster'
fi
grep -q 'unable to load in-cluster config' "$work/startup.log" || fail 'manager did not reach Kubernetes client configuration'

if docker run --rm --network none "$image" manager --not-a-real-flag >"$work/invalid.log" 2>&1; then
  fail 'invalid flag unexpectedly succeeded'
fi
grep -q 'not-a-real-flag' "$work/invalid.log" || fail 'invalid flag error was not reported'
rm -f "$work"/*.log

printf 'SMOKE PASS image=%s\n' "$image"
