#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
sandbox="verity-kube-proxy-test-$$"
filesystem_container=
kubeconfig=$(mktemp)
invalid_config=$(mktemp)
output=$(mktemp)
rootfs=$(mktemp)

fail() {
  docker logs "$sandbox" >&2 2>/dev/null || true
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  [ -z "$filesystem_container" ] || docker rm "$filesystem_container" >/dev/null 2>&1 || true
  docker rm -f "$sandbox" >/dev/null 2>&1 || true
  rm -f "$kubeconfig" "$invalid_config" "$output" "$rootfs"
}
trap cleanup EXIT INT TERM

[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/kube-proxy"]' ] || fail 'unexpected image entrypoint'
[ -z "$(docker image inspect --format '{{.Config.User}}' "$image")" ] || fail 'kube-proxy must run as root'
filesystem_container=$(docker create "$image")
docker export "$filesystem_container" | tar -tf - >"$rootfs"
grep -Fxq 'var/lib/kube-proxy/' "$rootfs" || fail 'missing /var/lib/kube-proxy'
grep -Fxq 'var/log/kube-proxy/' "$rootfs" || fail 'missing /var/log/kube-proxy'
docker rm "$filesystem_container" >/dev/null
filesystem_container=
docker run --rm --network none --cap-drop ALL "$image" --version | grep -Fq 'Kubernetes v1.36.' || fail 'unexpected kube-proxy version'

printf '%s\n' 'not: [valid kube-proxy configuration' >"$invalid_config"
chmod 644 "$invalid_config"
if docker run --rm --network none --cap-drop ALL \
  -v "$invalid_config:/var/lib/kube-proxy/config.yaml:ro" \
  "$image" --config /var/lib/kube-proxy/config.yaml >"$output" 2>&1; then
  fail 'invalid configuration unexpectedly started kube-proxy'
fi
grep -Fq 'failed to decode: yaml:' "$output" || fail 'invalid configuration did not reach YAML validation'

[ "${GITHUB_ACTIONS:-}" = true ] || fail 'privileged smoke test requires an isolated GitHub Actions runner'
cat >"$kubeconfig" <<'EOF'
apiVersion: v1
kind: Config
clusters:
- name: synthetic
  cluster:
    server: https://127.0.0.1:65535
    insecure-skip-tls-verify: true
users:
- name: synthetic
  user:
    token: synthetic-kube-proxy-test-token
contexts:
- name: synthetic
  context:
    cluster: synthetic
    user: synthetic
current-context: synthetic
EOF
chmod 644 "$kubeconfig"

docker run --name "$sandbox" -d --network none --cap-drop ALL --cap-add NET_ADMIN \
  --entrypoint /usr/bin/conntrack "$image" -E >/dev/null
[ "$(docker inspect --format '{{.State.Running}}' "$sandbox")" = true ] || fail 'private network namespace holder did not start'

if docker run --rm --network "container:$sandbox" --cap-drop ALL \
  --entrypoint /usr/bin/iptables "$image" -t nat -N KUBE-SERVICES >"$output" 2>&1; then
  fail 'iptables mutation succeeded without CAP_NET_ADMIN'
fi

docker run --rm --network "container:$sandbox" --cap-drop ALL --cap-add NET_ADMIN \
  -v "$kubeconfig:/var/lib/kube-proxy/kubeconfig:ro" "$image" \
  --init-only --proxy-mode=iptables --iptables-localhost-nodeports=false \
  --hostname-override=synthetic-node --kubeconfig=/var/lib/kube-proxy/kubeconfig >/dev/null

docker run --rm --network "container:$sandbox" --cap-drop ALL --cap-add NET_ADMIN \
  --entrypoint /usr/bin/iptables "$image" -t nat -S KUBE-SERVICES >/dev/null || \
  fail 'kube-proxy initialization did not create KUBE-SERVICES'

docker run --rm --network "container:$sandbox" --cap-drop ALL --cap-add NET_ADMIN \
  -v "$kubeconfig:/var/lib/kube-proxy/kubeconfig:ro" "$image" \
  --cleanup --proxy-mode=iptables --kubeconfig=/var/lib/kube-proxy/kubeconfig >/dev/null

if docker run --rm --network "container:$sandbox" --cap-drop ALL --cap-add NET_ADMIN \
  --entrypoint /usr/bin/iptables "$image" -t nat -S KUBE-SERVICES >"$output" 2>&1; then
  fail 'kube-proxy cleanup left KUBE-SERVICES behind'
fi

printf 'SMOKE PASS image=%s\n' "$image"
