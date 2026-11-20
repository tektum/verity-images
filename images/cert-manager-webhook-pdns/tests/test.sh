#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
curl_index='docker.io/curlimages/curl:8.14.1@sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b'
prefix="verity-cert-manager-webhook-pdns-test-$$"
server=$prefix-server
tmp=$(mktemp -d)

cleanup() {
  docker ps -aq --filter "name=^$prefix-" | xargs -r docker rm -f >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  docker logs --tail 40 "$server" >&2 2>&1 || true
  exit 1
}

inspect() {
  docker image inspect -f "$1" "$image"
}

# CI runs this script once per architecture on one host, and a classic image
# store cannot bind the index digest to a second platform's image. Pull the
# curl helper by its per-platform child digest after checking the index bytes
# against the pinned digest, which keeps the pin authoritative.
image_arch=$(inspect '{{.Architecture}}')
pull_child() {
  raw=$(docker buildx imagetools inspect --raw "$1") || fail "cannot inspect $1"
  [ "sha256:$(printf '%s' "$raw" | sha256sum | cut -d' ' -f1)" = "${1#*@}" ] ||
    fail "index digest mismatch for $1"
  child=$(printf '%s' "$raw" | jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') || fail "cannot resolve a child of $1"
  case $child in
    sha256:*) ;;
    *) fail "no unique linux/$image_arch child in $1" ;;
  esac
  docker pull --quiet --platform "linux/$image_arch" "${1%%@*}@$child" >/dev/null ||
    fail "cannot pull ${1%%@*}@$child"
  printf '%s' "${1%%@*}@$child"
}
curl_image=$(pull_child "$curl_index")

curl_in() {
  docker run --rm --network "container:$server" "$curl_image" "$@"
}

# --- OCI contract -----------------------------------------------------------
[ "$(inspect '{{.Config.User}}')" = 65532 ] || fail "unexpected OCI user: $(inspect '{{.Config.User}}')"
[ "$(inspect '{{json .Config.Entrypoint}}')" = '["/usr/bin/webhook"]' ] ||
  fail "unexpected OCI entrypoint: $(inspect '{{json .Config.Entrypoint}}')"

# --- Negative: no GROUP_NAME fails fast ---------------------------------------
if out=$(timeout 30 docker run --rm --network none "$image" 2>&1); then
  fail 'webhook without GROUP_NAME exited 0'
fi
printf '%s\n' "$out" | grep -q 'GROUP_NAME must be specified' || fail "missing GROUP_NAME not reported: $out"

# --- Negative: no cluster fails fast ------------------------------------------
if out=$(timeout 30 docker run --rm --network none -e GROUP_NAME=acme.verity.test "$image" \
  --cert-dir=/tmp/certs --secure-port=8443 2>&1); then
  fail 'webhook without a cluster exited 0'
fi
printf '%s\n' "$out" | grep -q 'unable to load in-cluster configuration' ||
  fail "missing cluster configuration not reported: $out"

# --- TLS health with an unreachable API server --------------------------------
# A kubeconfig pointing at a closed port lets the apiserver framework start without a cluster.
cat > "$tmp/kubeconfig" <<'KC'
apiVersion: v1
kind: Config
clusters: [{name: none, cluster: {server: "https://127.0.0.1:1", insecure-skip-tls-verify: true}}]
users: [{name: none, user: {token: none}}]
contexts: [{name: none, context: {cluster: none, user: none}}]
current-context: none
KC
chmod 644 "$tmp/kubeconfig"
docker run -d --name "$server" --network none -v "$tmp/kubeconfig:/kubeconfig:ro" \
  -e GROUP_NAME=acme.verity.test "$image" \
  --cert-dir=/tmp/certs --secure-port=8443 --kubeconfig=/kubeconfig \
  --authentication-kubeconfig=/kubeconfig --authorization-kubeconfig=/kubeconfig \
  --authentication-skip-lookup >/dev/null || fail 'docker run (server) failed'

ready=
for _ in $(seq 1 30); do
  if [ "$(docker inspect -f '{{.State.Running}}' "$server")" != true ]; then
    fail 'webhook server exited'
  fi
  if docker logs "$server" 2>&1 | grep -q 'Serving securely on'; then
    ready=1
    break
  fi
  sleep 1
done
[ -n "$ready" ] || fail 'webhook server did not start serving TLS'
docker logs "$server" 2>&1 | grep -q 'Adding GroupVersion acme.verity.test v1alpha1' ||
  fail 'solver API group was not registered'

for path in healthz livez readyz; do
  body=$(curl_in -fsSk "https://127.0.0.1:8443/$path") || fail "GET /$path over TLS failed"
  [ "$body" = ok ] || fail "unexpected /$path body: $body"
done
# Plain HTTP on the secure port must not be served.
status=$(curl_in -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8443/healthz) || true
[ "$status" = 400 ] || [ "$status" = 000 ] || fail "plain HTTP /healthz returned $status"
# The solver API needs delegated authorization; with no reachable cluster it must not answer 200.
status=$(curl_in -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:8443/apis/acme.verity.test/v1alpha1)
[ "$status" != 200 ] || fail 'solver API answered 200 without authorization'

# --- Clean SIGTERM shutdown ---------------------------------------------------
docker stop -t 20 "$server" >/dev/null
code=$(docker inspect -f '{{.State.ExitCode}}' "$server")
[ "$code" = 0 ] || fail "unexpected exit code after SIGTERM: $code"

printf 'SMOKE PASS\n'
