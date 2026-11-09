#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)

trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/manager"]' || fail 'unexpected entrypoint'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'CA bundle environment is missing'

docker run --rm --network none --read-only "$image" --help >"$work/help" 2>&1 ||
  fail '--help failed'
grep -F 'OpenTelemetry Operator manages OpenTelemetry Collectors' "$work/help" >/dev/null ||
  fail 'help does not identify the OpenTelemetry operator'
for flag in --config-file --collector-image --target-allocator-image --enable-leader-election \
  --webhook-port --enable-java-instrumentation; do
  grep -F -e "$flag" "$work/help" >/dev/null || fail "operator help is missing $flag"
done
grep -F 'webhook-server' "$work/help" >/dev/null || fail 'webhook-server command is missing'

docker run --rm --network none --read-only "$image" webhook-server --help >"$work/webhook" 2>&1 ||
  fail 'webhook-server --help failed'
grep -F 'Run only the webhooks' "$work/webhook" >/dev/null || fail 'webhook-server help is wrong'

if docker run --rm --network none --read-only "$image" --definitely-invalid \
  >"$work/invalid" 2>&1; then
  fail 'invalid argument unexpectedly succeeded'
fi
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'invalid argument diagnostic is missing'

# Every default component image must carry the version stamped from the
# upstream versions.txt; an empty stamp would leave an untagged image.
for flag in --collector-image --target-allocator-image --operator-opamp-bridge-image \
  --auto-instrumentation-java-image --auto-instrumentation-nodejs-image \
  --auto-instrumentation-python-image --auto-instrumentation-dotnet-image \
  --auto-instrumentation-go-image --auto-instrumentation-php-image \
  --auto-instrumentation-ruby-image --auto-instrumentation-apache-httpd-image \
  --auto-instrumentation-nginx-image; do
  grep -E -e "^ +$flag string .*\(default \"[^\":]+/[^\":]+:[^\":]+\"\)" "$work/help" >/dev/null ||
    fail "$flag has no stamped default image tag"
done

# Outside a cluster the operator must start, report its stamped version and
# default component images, then exit non-zero on the missing cluster config.
if docker run --rm --network none --read-only "$image" >"$work/startup" 2>&1; then
  fail 'startup without a cluster unexpectedly succeeded'
fi
grep -F 'Starting the OpenTelemetry Operator' "$work/startup" >/dev/null ||
  fail 'startup banner is missing'
grep -E '"opentelemetry-operator":"[0-9]+\.[0-9]+\.[0-9]+"' "$work/startup" >/dev/null ||
  fail 'operator version was not stamped into the binary'
grep -E 'opentelemetry-operator/autoinstrumentation-java:[0-9]+\.[0-9]+' "$work/startup" >/dev/null ||
  fail 'default auto-instrumentation image versions were not stamped'
grep -F 'unable to load in-cluster configuration, KUBERNETES_SERVICE_HOST and KUBERNETES_SERVICE_PORT must be defined' \
  "$work/startup" >/dev/null || fail 'missing cluster configuration diagnostic is missing'

printf 'SMOKE PASS image=%s\n' "$image"
