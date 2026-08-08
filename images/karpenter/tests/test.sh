#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-karpenter-test-$$"
help_container="${container}-help"
missing_container="${container}-missing"
fixture=$(mktemp -d)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker rm -f "$help_container" >/dev/null 2>&1 || true
  docker rm -f "$missing_container" >/dev/null 2>&1 || true
  rm -rf "$fixture"
}
trap cleanup EXIT INT TERM

test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/controller"]'
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532

# Happy path: --help succeeds before any cluster config is read.
docker run --name "$help_container" --user 65532 "$image" --help \
  >"$fixture/help.log" 2>&1
grep -Eqi 'metrics-port|health-probe-port|kube-client-qps' "$fixture/help.log"

# Happy path: read-only-root startup with a syntactically valid but unreachable
# kubeconfig reaches the liveness endpoint, which does not depend on cluster access.
cat > "$fixture/kubeconfig" <<'EOF'
apiVersion: v1
kind: Config
clusters:
  - name: smoke
    cluster:
      server: https://127.0.0.1:1
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
chmod 644 "$fixture/kubeconfig"

docker run --name "$container" -d --read-only --user 65532 \
  --tmpfs /tmp:uid=65532,gid=65532 \
  -v "$fixture/kubeconfig:/tmp/kubeconfig:ro" \
  -e KUBECONFIG=/tmp/kubeconfig \
  -e DISABLE_LEADER_ELECTION=true \
  -p 127.0.0.1::8081 "$image" >/dev/null
health_port=$(docker port "$container" 8081/tcp | awk -F: 'NR == 1 { print $2 }')
test -n "$health_port" || { docker logs "$container" >&2 || true; exit 1; }

i=0
until curl --fail --silent --output /dev/null --connect-timeout 1 --max-time 5 \
  "http://127.0.0.1:$health_port/healthz"; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || { docker logs "$container" >&2 || true; exit 1; }
  sleep 1
done
test "$(docker inspect -f '{{.State.Running}}' "$container")" = true

# Failure path: no kubeconfig, no in-cluster service account, and no
# KUBERNETES_SERVICE_HOST/PORT means the controller cannot resolve cluster
# config and must exit nonzero.
if docker run --name "$missing_container" --user 65532 "$image" \
  >"$fixture/missing-config.log" 2>&1; then
  printf 'missing cluster config unexpectedly succeeded\n' >&2
  cat "$fixture/missing-config.log" >&2
  exit 1
fi
grep -F 'unable to get kubeconfig' "$fixture/missing-config.log"

printf 'SMOKE PASS image=%s\n' "$image"
