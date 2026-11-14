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

# The upstream ko image runs as 65532 with only an entrypoint, and the Helm chart
# passes flags through args, so any entrypoint path stays drop-in.
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/grafana-operator"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'CA bundle environment is missing'

docker run --rm --network none --read-only "$image" --help >"$work/help" 2>&1 ||
  fail "operator --help failed: $(cat "$work/help")"
grep -F 'Usage: grafana-operator [flags]' "$work/help" >/dev/null || fail 'help usage line is missing'
# Every flag the upstream Helm chart passes, plus the scoping flags it sets by env.
for flag in --health-probe-bind-address --metrics-bind-address --pprof-addr --zap-encoder \
  --zap-log-level --zap-time-encoding --default-resync-period --leader-elect \
  --max-concurrent-reconciles --gomemlimit-ratio --watch-namespace --watch-namespace-selector \
  --watch-label-selectors --caching-level --cluster-domain; do
  grep -F -e "  $flag" "$work/help" >/dev/null || fail "operator help is missing $flag"
done
grep -F "(\$ENABLE_LEADER_ELECTION)" "$work/help" >/dev/null ||
  fail 'help does not document the leader election environment variable'

status=0
docker run --rm --network none --read-only "$image" --definitely-invalid \
  >"$work/invalid" 2>&1 || status=$?
test "$status" = 80 || fail "invalid argument exited $status, want 80"
grep -F 'grafana-operator: error: unknown flag --definitely-invalid' "$work/invalid" >/dev/null ||
  fail "invalid argument diagnostic is missing: $(cat "$work/invalid")"

# Outside a cluster and without a kubeconfig the manager must fail fast, not crash-loop.
status=0
timeout 60 docker run --rm --network none --read-only "$image" \
  --health-probe-bind-address=:8081 --metrics-bind-address=0.0.0.0:9090 --leader-elect \
  >"$work/nocluster" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail 'operator outside a cluster unexpectedly succeeded'
[ "$status" -ne 124 ] || fail 'operator hung outside a cluster instead of failing fast'
grep -F 'unable to load in-cluster configuration, KUBERNETES_SERVICE_HOST and KUBERNETES_SERVICE_PORT must be defined' \
  "$work/nocluster" >/dev/null || fail "in-cluster diagnostic is missing: $(cat "$work/nocluster")"

# A kubeconfig naming an unreachable API server passes config loading and fails at
# platform discovery. The operator has no version flag; its setup logger stamps
# every line with the build version, which also becomes its Grafana User-Agent.
cat >"$work/kubeconfig" <<'EOF'
apiVersion: v1
kind: Config
clusters:
  - name: unreachable
    cluster:
      server: https://10.255.255.1:6443
      insecure-skip-tls-verify: true
contexts:
  - name: unreachable
    context:
      cluster: unreachable
      user: unreachable
current-context: unreachable
users:
  - name: unreachable
    user:
      token: unreachable
EOF
chmod 0755 "$work"
chmod 0644 "$work/kubeconfig"

status=0
timeout 60 docker run --rm --network none --read-only \
  -e KUBECONFIG=/tmp/kubeconfig -v "$work/kubeconfig:/tmp/kubeconfig:ro" "$image" \
  >"$work/unreachable" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail 'operator with an unreachable API server unexpectedly succeeded'
[ "$status" -ne 124 ] || fail 'operator hung on an unreachable API server instead of failing fast'
grep -F 'unable to detect the platform' "$work/unreachable" >/dev/null ||
  fail "platform discovery diagnostic is missing: $(cat "$work/unreachable")"
grep -F 'dial tcp 10.255.255.1:6443' "$work/unreachable" >/dev/null ||
  fail "connection error is missing: $(cat "$work/unreachable")"
grep -F "\"version\": \"v$expected_version\"" "$work/unreachable" >/dev/null ||
  fail "operator does not report v$expected_version: $(grep -o '"version": "[^"]*"' "$work/unreachable" | sort -u)"

printf 'SMOKE PASS image=%s\n' "$image"
