#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-kube-state-metrics-test-$$"
fixture=$(mktemp -d)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$fixture"
}
trap cleanup EXIT INT TERM

test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/kube-state-metrics"]'
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532

cat > "$fixture/kubeconfig" <<'EOF'
apiVersion: v1
kind: Config
clusters:
  - name: fixture
    cluster:
      server: http://127.0.0.1:65535
contexts:
  - name: fixture
    context:
      cluster: fixture
      user: fixture
current-context: fixture
users:
  - name: fixture
    user: {}
EOF
chmod 644 "$fixture/kubeconfig"

docker run --name "$container" -d --read-only --user 65532 \
  --tmpfs /tmp:uid=65532,gid=65532 \
  -v "$fixture/kubeconfig:/tmp/kubeconfig:ro" \
  -p 127.0.0.1::8080 "$image" \
  --kubeconfig=/tmp/kubeconfig --port=8080 >/dev/null
port=$(docker port "$container" 8080/tcp | awk -F: 'NR == 1 { print $2 }')
test -n "$port" || { docker logs "$container" >&2 || true; exit 1; }

for _ in $(seq 1 100); do
  if curl --fail --silent --connect-timeout 1 --max-time 5 "http://127.0.0.1:$port/metrics" > "$fixture/metrics"; then
    break
  fi
  sleep 0.1
done
grep -q '^kube_state_metrics_build_info{' "$fixture/metrics" || {
  docker logs "$container" >&2
  printf 'metrics endpoint did not expose build info\n' >&2
  exit 1
}

printf 'apiVersion: [' > "$fixture/invalid-kubeconfig"
chmod 644 "$fixture/invalid-kubeconfig"
if docker run --rm --user 65532 \
  -v "$fixture/invalid-kubeconfig:/tmp/kubeconfig:ro" \
  "$image" --kubeconfig=/tmp/kubeconfig >/dev/null 2>&1; then
  printf 'invalid kubeconfig unexpectedly succeeded\n' >&2
  exit 1
fi

printf 'SMOKE PASS image=%s\n' "$image"
