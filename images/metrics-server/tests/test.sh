#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-metrics-server-test-$$"
image_container="${container}-image"
kubeconfig=$(mktemp)

# cleanup removes the test containers and temporary kubeconfig file.
cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker rm -f "$image_container" >/dev/null 2>&1 || true
  rm -f "$kubeconfig"
}
trap cleanup EXIT INT TERM

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 1000 ]
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/metrics-server"]' ]
[ "$(docker image inspect -f '{{json .Config.Cmd}}' "$image")" = '["--secure-port=10250","--cert-dir=/tmp"]' ]
docker create --name "$image_container" "$image" >/dev/null
tmp_metadata=$(docker export "$image_container" | tar -tvf - | grep -E ' (\./)?tmp/?$')
printf '%s\n' "$tmp_metadata" | grep -Eq '^drwxrwxrwt +1000/1000 +[0-9]+ .* (\./)?tmp/?$'

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

sleep 2
[ "$(docker inspect -f '{{.State.Running}}' "$container")" = true ]
docker logs "$container" 2>&1 | grep -F 'Generated self-signed cert (/tmp/apiserver.crt, /tmp/apiserver.key)'
