#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/kube-controller-manager"]' ] || fail 'unexpected OCI entrypoint'
channel=$(awk '/^versions:/ { gsub(/[\[\],]/, ""); print $2; exit }' "$(dirname -- "$0")/../metadata.yaml")
[ -n "$channel" ] || fail 'supported version channel missing from metadata'
version=$(docker run --rm --network none --read-only "$image" --version)
case "$version" in
  "Kubernetes v${channel}".*) ;;
  *) fail "unexpected kube-controller-manager version for channel ${channel}: ${version}" ;;
esac
docker run --rm --network none --read-only "$image" --help >/dev/null || fail 'kube-controller-manager help failed'

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
chmod 644 "$work/kubeconfig"

if invalid_output=$(docker run --rm --network none --read-only \
  -v "$work/kubeconfig:/tmp/kubeconfig:ro" \
  "$image" --kubeconfig=/tmp/kubeconfig \
  --leader-elect-lease-duration=1s --leader-elect-renew-deadline=2s 2>&1); then
  fail 'invalid leader election configuration unexpectedly succeeded'
fi
case "$invalid_output" in
  *"leaseDuration must be greater than renewDeadline"*) ;;
  *)
    printf '%s\n' "$invalid_output" >&2
    fail 'invalid leader election diagnostic missing'
    ;;
esac

printf 'SMOKE PASS image=%s\n' "$image"
