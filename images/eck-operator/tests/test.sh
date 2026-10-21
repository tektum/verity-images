#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
container=
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml" | head -n 1)
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }

cleanup() {
  [ -z "$container" ] || docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  for log in "$work"/*.log; do
    [ ! -f "$log" ] || { printf '== %s\n' "$log" >&2; cat "$log" >&2; }
  done
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/elastic-operator"]' ] || fail 'unexpected entrypoint'
[ "$(docker image inspect -f '{{json .Config.Cmd}}' "$image")" = '["manager"]' ] || fail 'unexpected command'

env=$(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$image")
printf '%s\n' "$env" | grep -qx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' || fail 'missing CA configuration'

container=$(docker create "$image")
for asset in /etc/ssl/certs/ca-certificates.crt /conf/eck.yaml /licenses/LICENSE.txt /licenses/NOTICE.txt; do
  docker cp "$container:$asset" "$work/" >/dev/null || fail "missing asset $asset"
done
docker rm "$container" >/dev/null
container=

docker run --rm --network none "$image" --help >"$work/help.log" 2>&1 || fail 'operator help failed'
grep -q 'Elastic Cloud on Kubernetes (ECK) operator' "$work/help.log" || fail 'operator help output is invalid'
grep -q 'manager.*Start the Elastic Cloud on Kubernetes operator' "$work/help.log" || fail 'operator help omits manager command'

docker run --rm --network none "$image" manager --help >"$work/manager-help.log" 2>&1 || fail 'manager help failed'
grep -q 'Start the Elastic Cloud on Kubernetes operator' "$work/manager-help.log" || fail 'manager help output is invalid'

docker run --rm --network none "$image" >"$work/startup.log" 2>&1 || fail 'default manager startup failed'
grep -q '"service.version":"'"$expected_version"'+' "$work/startup.log" || fail 'default command did not start ECK manager'
grep -q 'Required configuration missing' "$work/startup.log" || fail 'manager did not reach configuration validation'

# ECK reports Cobra argument errors on stderr while preserving its upstream zero exit status.
docker run --rm --network none "$image" manager --not-a-real-flag >"$work/invalid.log" 2>&1
grep -q 'Error: unknown flag: --not-a-real-flag' "$work/invalid.log" || fail 'invalid argument did not report the expected error'

printf 'SMOKE PASS image=%s\n' "$image"
