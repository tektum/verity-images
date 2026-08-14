#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
tmp=$(mktemp -d)
container="verity-metallb-speaker-test-$$"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/speaker"]'
test -z "$(docker image inspect --format '{{.Config.User}}' "$image")"

docker run --rm --network none --read-only --user 65534:65534 \
  --cap-drop ALL --security-opt no-new-privileges \
  "$image" --help 2>&1 | grep -F -- '-node-name string' >/dev/null \
  || fail 'speaker help failed without network or capabilities'

if docker run --rm --network none --read-only --user 65534:65534 \
  --cap-drop ALL --security-opt no-new-privileges \
  "$image" --namespace smoke --node-name smoke >"$tmp/unprivileged.log" 2>&1; then
  fail 'speaker unexpectedly started without its Kubernetes runtime'
fi
grep -F 'unable to get kubeconfig' "$tmp/unprivileged.log" >/dev/null \
  || fail 'speaker did not reach the expected safe failure boundary'

if [ "${CI:-}" = true ]; then
  cat >"$tmp/kubeconfig" <<'EOF'
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
  docker run --name "$container" -d --network host --read-only \
    --cap-drop ALL --cap-add NET_RAW --security-opt no-new-privileges \
    -e KUBECONFIG=/tmp/kubeconfig -v "$tmp/kubeconfig:/tmp/kubeconfig:ro" \
    "$image" --namespace smoke --node-name smoke --port=0 >/dev/null

  i=0
  until docker logs "$container" 2>&1 | grep -F 'created ARP responder for interface' >/dev/null; do
    [ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ] \
      || { docker logs "$container" >&2; fail 'speaker exited before creating an ARP responder'; }
    i=$((i + 1))
    [ "$i" -lt 20 ] || { docker logs "$container" >&2; fail 'speaker did not create an ARP responder'; }
    sleep 1
  done
  docker logs "$container" 2>&1 | grep -E 'failed to create (ARP|NDP) responder' >/dev/null \
    && fail 'speaker could not initialize its raw-socket responders with NET_RAW'
  docker rm -f "$container" >/dev/null
fi

printf 'SMOKE PASS image=%s\n' "$image"
