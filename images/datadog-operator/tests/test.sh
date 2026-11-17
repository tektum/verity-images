#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
config="$here/../apko.yaml"
version=$(sed -n 's/^    - datadog-operator=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail 'could not read the pinned datadog-operator version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/manager"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

# Every run uses --network none, so no path in this test can reach the Datadog API.
docker run --rm --network none "$image" -version >"$work/version" 2>&1 ||
  fail 'version failed'
grep -Fx -- "- Version: $version" "$work/version" >/dev/null ||
  fail "version does not report datadog-operator $version: $(cat "$work/version")"

docker run --rm --network none "$image" -help >"$work/help" 2>&1 || true
grep -F -- '-datadogMonitorEnabled' "$work/help" >/dev/null ||
  fail "help does not list operator controllers: $(cat "$work/help")"

rc=0
docker run --rm --network none "$image" -definitely-invalid >"$work/invalid" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"

# The secret backend helper ships beside the manager and speaks the Agent
# secret backend protocol on stdin and stdout.
mkdir -p "$work/secrets"
printf 'smoke-api-key' >"$work/secrets/api_key"
chmod -R a+rX "$work/secrets"
printf '{"version":"1.0","secrets":["api_key","missing"]}' |
  docker run -i --rm --network none --read-only --cap-drop=ALL \
    -v "$work/secrets:/etc/secret-volume:ro" --entrypoint /usr/bin/helpers "$image" \
    read-secret /etc/secret-volume >"$work/secret.json" 2>"$work/secret.err" ||
  fail "read-secret failed: $(cat "$work/secret.err")"
grep -F '"api_key":{"value":"smoke-api-key"}' "$work/secret.json" >/dev/null ||
  fail "read-secret did not return the mounted secret: $(cat "$work/secret.json")"
grep -F '"missing":{"error":"secret does not exist"}' "$work/secret.json" >/dev/null ||
  fail "read-secret did not report the missing secret: $(cat "$work/secret.json")"

# Out of cluster, the manager must start, read the kubeconfig and fail on the
# unreachable Kubernetes API rather than crash or contact anything else.
cat >"$work/kubeconfig" <<'EOF'
apiVersion: v1
kind: Config
clusters:
- name: smoke
  cluster:
    server: http://127.0.0.1:1
contexts:
- name: smoke
  context:
    cluster: smoke
    user: smoke
current-context: smoke
users:
- name: smoke
  user:
    token: smoke
EOF
chmod 0644 "$work/kubeconfig"
rc=0
timeout 120 docker run --rm --network none --read-only --cap-drop=ALL \
  -v "$work/kubeconfig:/etc/kubeconfig:ro" "$image" \
  -kubeconfig /etc/kubeconfig -enable-leader-election=false -operatorMetricsEnabled=false \
  >"$work/manager.log" 2>&1 || rc=$?
test "$rc" -ne 0 -a "$rc" -ne 124 ||
  fail "manager did not exit with an API error (status $rc): $(cat "$work/manager.log")"
grep -F '"msg":"Version: '"$version"'"' "$work/manager.log" >/dev/null ||
  fail "manager did not log its version: $(cat "$work/manager.log")"
grep -F '"msg":"Unable to start manager"' "$work/manager.log" >/dev/null ||
  fail "manager did not report the start failure: $(cat "$work/manager.log")"
grep -F 'Get \"http://127.0.0.1:1/api\"' "$work/manager.log" >/dev/null ||
  fail "manager did not contact the configured API server: $(cat "$work/manager.log")"
if grep -F 'datadoghq.com' "$work/manager.log" >/dev/null; then
  fail 'manager attempted to reach a Datadog endpoint'
fi

# Without in-cluster credentials or a kubeconfig the manager refuses to start.
rc=0
timeout 60 docker run --rm --network none --read-only "$image" \
  -enable-leader-election=false >"$work/nocluster" 2>&1 || rc=$?
test "$rc" -ne 0 -a "$rc" -ne 124 || fail 'manager started without Kubernetes configuration'
grep -F 'unable to load in-cluster config' "$work/nocluster" >/dev/null ||
  fail "missing in-cluster configuration diagnostic: $(cat "$work/nocluster")"

echo 'SMOKE PASS'
