#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE [FLAVOR]}
flavor=${2:-plain}
work=$(mktemp -d)
container=
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_image=$(awk '$1 == "image:" {print $2}' "$source_dir/source.yaml")
source_tag=${source_image##*:}
expected_version=${source_tag#v}
expected_version=${expected_version%%-*}

cleanup() {
  [ -z "$container" ] || docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

case $flavor in plain) ;; *) fail "unsupported flavor $flavor" ;; esac

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/elastic-operator"]' ] || fail 'unexpected entrypoint'
[ "$(docker image inspect -f '{{json .Config.Cmd}}' "$image")" = '["manager"]' ] || fail 'unexpected command'
[ "$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$image")" = "$expected_version" ] || fail 'unexpected image version label'

env=$(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$image")
printf '%s\n' "$env" | grep -qx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' || fail 'missing CA configuration'

container=$(docker create "$image")
for asset in /etc/ssl/certs/ca-certificates.crt /licenses/LICENSE.txt /licenses/NOTICE.txt /licenses/images-to-scan.txt /licenses/images-to-sign.txt; do
  docker cp "$container:$asset" "$work/" >/dev/null || fail "missing upstream asset $asset"
done
docker rm "$container" >/dev/null
container=

docker run --rm --network none "$image" --help >"$work/help.log" 2>&1 || fail 'operator help failed'
grep -q 'Elastic Cloud on Kubernetes (ECK) operator' "$work/help.log" || fail 'operator help output is invalid'
grep -q 'manager.*Start the Elastic Cloud on Kubernetes operator' "$work/help.log" || fail 'operator help omits manager command'

docker run --rm --network none "$image" manager --help >"$work/manager-help.log" 2>&1 || fail 'manager help failed'
grep -q 'Start the Elastic Cloud on Kubernetes operator' "$work/manager-help.log" || fail 'manager help output is invalid'

docker run --rm --network none "$image" >"$work/startup.log" 2>&1 || fail 'default manager startup failed'
grep -q '"service.version":"'$expected_version'+' "$work/startup.log" || fail 'default command did not start ECK manager'
grep -q 'Required configuration missing' "$work/startup.log" || fail 'manager did not reach configuration validation'

# ECK reports Cobra argument errors on stderr while preserving its upstream zero exit status.
docker run --rm --network none "$image" manager --not-a-real-flag >"$work/invalid.log" 2>&1
grep -q 'Error: unknown flag: --not-a-real-flag' "$work/invalid.log" || fail 'invalid argument did not report the expected error'

printf 'SMOKE PASS image=%s\n' "$image"
