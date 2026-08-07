#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-metrics-server-test-$$"
kubeconfig=$(mktemp)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -f "$kubeconfig"
}
trap cleanup EXIT INT TERM

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 1000 ]
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/metrics-server"]' ]
[ "$(docker image inspect -f '{{json .Config.Cmd}}' "$image")" = '["--secure-port=10250","--cert-dir=/tmp"]' ]

cat > "$kubeconfig" <<'EOF'
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
chmod 644 "$kubeconfig"

docker run --name "$container" -d --read-only --user 1000 \
  --tmpfs /tmp:uid=1000,gid=1000,mode=1777 \
  -v "$kubeconfig:/tmp/kubeconfig:ro" \
  -p 127.0.0.1::10250 "$image" \
  --secure-port=10250 \
  --cert-dir=/tmp \
  --kubeconfig=/tmp/kubeconfig \
  --authentication-kubeconfig=/tmp/kubeconfig \
  --authorization-kubeconfig=/tmp/kubeconfig \
  --authentication-skip-lookup >/dev/null
port=$(docker port "$container" 10250/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || { docker logs "$container" >&2 || true; exit 1; }

i=0
until curl --silent --insecure --connect-timeout 1 --max-time 5 "https://127.0.0.1:$port/livez" >/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 20 ] || { docker logs "$container" >&2 || true; exit 1; }
  sleep 1
done

if curl --fail --silent --connect-timeout 1 --max-time 5 "http://127.0.0.1:$port/livez" >/dev/null 2>&1; then
  exit 1
fi
