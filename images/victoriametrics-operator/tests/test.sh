#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d)

trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/vm-operator"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'CA bundle environment is missing'

docker run --rm --network none --read-only "$image" -version >"$work/version" 2>&1 ||
  fail 'operator -version failed'
grep -Ex "operator-[0-9]{8}-[0-9]{6}-v${expected_version}" "$work/version" >/dev/null ||
  fail "unexpected version output: $(cat "$work/version")"

docker run --rm --network none --read-only "$image" -help >"$work/help" 2>&1 || true
for flag in -leader-elect -metrics-bind-address -health-probe-bind-address -webhook.enable \
  -controller.maxConcurrentReconciles -printDefaults -zap-log-level; do
  grep -F -e "  $flag" "$work/help" >/dev/null || fail "operator help is missing $flag"
done

if docker run --rm --network none --read-only "$image" --definitely-invalid \
  >"$work/invalid" 2>&1; then
  fail 'invalid argument unexpectedly succeeded'
fi
grep -F 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'invalid argument diagnostic is missing'

# VM_OPERATOR_VERSION is parsed from the stamped build info and selects the
# config-reloader sidecar tag the operator deploys, so it must be exactly this
# release (a git-describe suffix would point at a tag that does not exist).
# Component defaults must also stay overridable by env.
docker run --rm --network none --read-only "$image" -printDefaults -printFormat yaml \
  >"$work/defaults" 2>&1 || fail "printDefaults failed: $(cat "$work/defaults")"
grep -Fx "VM_OPERATOR_VERSION: 'v${expected_version}'" "$work/defaults" >/dev/null ||
  fail "operator version default is wrong: $(grep VM_OPERATOR_VERSION "$work/defaults" || true)"
grep -E "^VM_METRICS_VERSION: 'v[0-9]+\.[0-9]+\.[0-9]+'$" "$work/defaults" >/dev/null ||
  fail 'VictoriaMetrics component default is missing'
docker run --rm --network none --read-only -e VM_METRICS_VERSION=v9.9.9 "$image" \
  -printDefaults -printFormat yaml >"$work/override" 2>&1 || fail 'printDefaults with an override failed'
grep -Fx "VM_METRICS_VERSION: 'v9.9.9'" "$work/override" >/dev/null ||
  fail 'environment override of a component version was ignored'

# The operator logs this error before its logger is configured, so the message
# is dropped; assert the exit status and that no defaults were printed instead.
status=0
docker run --rm --network none --read-only "$image" -printDefaults -printFormat bogus \
  >"$work/badformat" 2>&1 || status=$?
test "$status" = 1 || fail "unknown print format exited $status, want 1"
if grep -F VM_OPERATOR_VERSION "$work/badformat" >/dev/null; then
  fail 'unknown print format still printed defaults'
fi

# Outside a cluster and without a kubeconfig the manager must fail fast, not crash-loop.
status=0
timeout 60 docker run --rm --network none --read-only "$image" \
  >"$work/nocluster" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail 'operator outside a cluster unexpectedly succeeded'
[ "$status" -ne 124 ] || fail 'operator hung outside a cluster instead of failing fast'
grep -F 'unable to load in-cluster configuration, KUBERNETES_SERVICE_HOST and KUBERNETES_SERVICE_PORT must be defined' \
  "$work/nocluster" >/dev/null || fail "in-cluster diagnostic is missing: $(cat "$work/nocluster")"

printf 'SMOKE PASS image=%s\n' "$image"
