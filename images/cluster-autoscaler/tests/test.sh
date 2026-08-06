#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected OCI user'
docker run --rm --network none "$image" --help >/dev/null || fail '/usr/bin/cluster-autoscaler is not executable'
docker run --rm --network none --entrypoint /cluster-autoscaler "$image" --help >/dev/null || fail '/cluster-autoscaler is not executable'

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
chmod 755 "$work"
cat > "$work/kubeconfig" <<'EOF'
apiVersion: v1
kind: Config
clusters:
  - name: smoke
    cluster:
      server: https://127.0.0.1:1
      insecure-skip-tls-verify: true
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

if unsupported_output=$(docker run --rm --network none \
  -v "$work/kubeconfig:/tmp/kubeconfig:ro" \
  "$image" --kubeconfig=/tmp/kubeconfig --leader-elect=false \
  --write-status-configmap=false --cloud-provider=unsupported 2>&1); then
  fail 'unsupported cloud provider unexpectedly succeeded'
fi
case "$unsupported_output" in
  *"Unknown cloud provider: unsupported"*) ;;
  *)
    printf '%s\n' "$unsupported_output" >&2
    fail 'unsupported cloud provider diagnostic missing'
    ;;
esac

printf 'SMOKE PASS image=%s\n' "$image"
