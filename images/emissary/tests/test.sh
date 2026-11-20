#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# Peers for a real control plane: Verity etcd 3.7, kube-apiserver 1.37 and
# kubectl 1.35, pinned by digest.
etcd_index=ghcr.io/tektum/etcd@sha256:fc322841b20ac374159333e013fb417aa712e776380c53dc34ab8a1958c07fd2
api_index=ghcr.io/tektum/kube-apiserver@sha256:b46742424f608bb186b83390c41cbe7f97df411ae3cf8fc3e4578c096a6b57bd
kubectl_index=ghcr.io/tektum/kubectl@sha256:537780af388652be3a0130aacd6d1cfed24704ab6a820c6c7024602ec7777332

id=$$
network="verity-emissary-$id"
etcd="verity-emissary-etcd-$id"
api="verity-emissary-api-$id"
emissary="verity-emissary-$id"
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  docker logs "$emissary" 2>&1 | tail -n 40 >&2 || true
  exit 1
}

cleanup() {
  docker rm -f "$emissary" "$api" "$etcd" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

recipe="$here/../melange.yaml"
expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' "$recipe")
envoy_version=$(awk '$1 == "envoy-version:" { gsub(/"/, "", $2); print $2; exit }' "$recipe")
[ -n "$expected_version" ] || fail 'could not read the recipe version'
[ -n "$envoy_version" ] || fail 'could not read the Envoy version'

# OCI contract: the upstream image runs `busyambassador entrypoint` as UID 8888
# with HOME in /tmp/ambassador.
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 8888 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["busyambassador","entrypoint"]' || fail 'unexpected entrypoint'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx 'HOME=/tmp/ambassador' >/dev/null || fail 'HOME is not /tmp/ambassador'

run() {
  docker run --rm --network none --cap-drop=ALL --security-opt=no-new-privileges "$@"
}

run --entrypoint busyambassador "$image" version >"$work/version" 2>&1 ||
  fail "version failed: $(cat "$work/version")"
grep -Fx "Version $expected_version" "$work/version" >/dev/null ||
  fail "unexpected version output: $(cat "$work/version")"

run --entrypoint envoy "$image" --version >"$work/envoy-version" 2>&1 ||
  fail "envoy --version failed: $(cat "$work/envoy-version")"
grep -F "/$envoy_version/" "$work/envoy-version" >/dev/null ||
  fail "unexpected Envoy version: $(cat "$work/envoy-version")"

run --entrypoint diagd "$image" --help >"$work/diagd-help" 2>&1 ||
  fail "diagd --help failed: $(cat "$work/diagd-help")"
grep -F 'Run the diagnostic daemon.' "$work/diagd-help" >/dev/null ||
  fail "unexpected diagd help: $(cat "$work/diagd-help")"

status=0
run --entrypoint busyambassador "$image" definitely-invalid >"$work/invalid" 2>&1 || status=$?
test "$status" -ne 0 || fail 'unknown busyambassador command unexpectedly succeeded'

# Control plane: etcd and kube-apiserver with a static admin token.
mkdir -p "$work/pki" "$work/kube" "$work/manifests"
openssl genrsa -out "$work/pki/sa.key" 2048 2>/dev/null || fail 'could not generate the service account key'
token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
printf '%s,verity-admin,verity-admin,system:masters\n' "$token" >"$work/pki/tokens.csv"
cat >"$work/kube/config" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: smoke
    cluster:
      server: https://$api:6443
      insecure-skip-tls-verify: true
users:
  - name: admin
    user:
      token: $token
contexts:
  - name: smoke
    context:
      cluster: smoke
      user: admin
current-context: smoke
EOF

# Schema-less v3alpha1 CRDs for every getambassador.io kind Emissary watches;
# the published chart renders the same group, kinds and storage version.
: >"$work/manifests/crds.yaml"
for kind in AuthService ConsulResolver DevPortal Host KubernetesEndpointResolver \
  KubernetesServiceResolver Listener LogService Mapping Module RateLimitService \
  TCPMapping TLSContext TracingService; do
  singular=$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]')
  cat >>"$work/manifests/crds.yaml" <<EOF
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: ${singular}s.getambassador.io
spec:
  group: getambassador.io
  scope: Namespaced
  names:
    kind: $kind
    listKind: ${kind}List
    plural: ${singular}s
    singular: $singular
  versions:
    - name: v3alpha1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          x-kubernetes-preserve-unknown-fields: true
EOF
done

# One HTTP listener, a catch-all Host that routes cleartext, and a Mapping
# whose response Envoy generates itself, so no backend is needed.
cat >"$work/manifests/config.yaml" <<'EOF'
apiVersion: getambassador.io/v3alpha1
kind: Listener
metadata:
  name: smoke-http
  namespace: default
spec:
  port: 8080
  protocol: HTTP
  securityModel: INSECURE
  hostBinding:
    namespace:
      from: ALL
---
apiVersion: getambassador.io/v3alpha1
kind: Host
metadata:
  name: smoke
  namespace: default
spec:
  hostname: "*"
  acmeProvider:
    authority: none
  requestPolicy:
    insecure:
      action: Route
---
apiVersion: getambassador.io/v3alpha1
kind: Mapping
metadata:
  name: smoke-redirect
  namespace: default
spec:
  hostname: "*"
  prefix: /smoke/
  service: verity-redirect.example
  host_redirect: true
EOF
chmod 0644 "$work/pki/sa.key" "$work/pki/tokens.csv" "$work/kube/config" "$work/manifests/"*.yaml

# pull_child INDEX: pull the pinned index by its per-platform child digest,
# verifying the index bytes against the pin first so the pin stays authoritative.
# The publish job runs this test per architecture against one daemon, so an
# index digest must never be passed straight to docker run.
image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
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
etcd_image=$(pull_child "$etcd_index")
api_image=$(pull_child "$api_index")
kubectl_image=$(pull_child "$kubectl_index")

docker network create "$network" >/dev/null
docker run -d --name "$etcd" --network "$network" --tmpfs /var/lib/etcd:uid=65532,gid=65532 \
  "$etcd_image" --data-dir=/var/lib/etcd/data \
  --listen-client-urls=http://0.0.0.0:2379 --advertise-client-urls="http://$etcd:2379" >/dev/null
docker run -d --name "$api" --network "$network" --tmpfs /tmp:uid=65532,gid=65532 \
  -v "$work/pki:/pki:ro" "$api_image" \
  --etcd-servers="http://$etcd:2379" --secure-port=6443 --cert-dir=/tmp \
  --token-auth-file=/pki/tokens.csv --authorization-mode=RBAC \
  --service-account-issuer=https://kubernetes.default.svc \
  --service-account-key-file=/pki/sa.key --service-account-signing-key-file=/pki/sa.key \
  --service-cluster-ip-range=10.96.0.0/16 >/dev/null

kubectl() {
  docker run --rm -i --network "$network" -v "$work/kube:/kube:ro" -v "$work/manifests:/manifests:ro" \
    -e KUBECONFIG=/kube/config "$kubectl_image" "$@"
}

i=0
until kubectl get --raw /readyz >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'kube-apiserver did not become ready'
  sleep 2
done
kubectl apply -f /manifests/crds.yaml >/dev/null || fail 'could not create the CRDs'
kubectl wait --for condition=established --timeout=60s crd --all >/dev/null ||
  fail 'CRDs were not established'
kubectl apply -f /manifests/config.yaml >/dev/null || fail 'could not create the Emissary resources'

# Emissary runs out of cluster as its default user with all capabilities
# dropped; /ambassador and /tmp/ambassador are written by the image user.
docker run -d --name "$emissary" --network "$network" --cap-drop=ALL --security-opt=no-new-privileges \
  -v "$work/kube:/kube:ro" -e KUBECONFIG=/kube/config -e AMBASSADOR_NAMESPACE=default \
  -e SCOUT_DISABLE=1 -p 127.0.0.1::8080 -p 127.0.0.1::8877 "$image" >/dev/null ||
  fail 'could not start emissary'
http_port=$(docker port "$emissary" 8080/tcp | awk -F: 'NR == 1 { print $2 }')
admin_port=$(docker port "$emissary" 8877/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$http_port" ] && [ -n "$admin_port" ] || fail 'ports 8080 and 8877 were not published'

running() {
  test "$(docker inspect --format '{{.State.Running}}' "$emissary")" = true
}

i=0
until curl --fail --silent --max-time 5 "http://127.0.0.1:$admin_port/ambassador/v0/check_ready" >"$work/ready" 2>&1; do
  running || fail 'emissary exited before becoming ready'
  i=$((i + 1))
  [ "$i" -lt 150 ] || fail 'emissary did not become ready'
  sleep 2
done
curl --fail --silent --max-time 5 "http://127.0.0.1:$admin_port/ambassador/v0/check_alive" >/dev/null ||
  fail 'check_alive failed'

# The Mapping is served by Envoy as a host redirect once the Kubernetes
# snapshot has gone through diagd and ambex.
i=0
until curl --silent --max-time 5 -o /dev/null -D "$work/redirect" "http://127.0.0.1:$http_port/smoke/path?q=1" &&
  grep -E '^HTTP/1\.1 301' "$work/redirect" >/dev/null; do
  running || fail 'emissary exited before serving the Mapping'
  i=$((i + 1))
  [ "$i" -lt 90 ] || fail "Mapping was not served: $(cat "$work/redirect" 2>/dev/null)"
  sleep 2
done
tr -d '\r' <"$work/redirect" | grep -Fx 'location: http://verity-redirect.example/smoke/path?q=1' >/dev/null ||
  fail "unexpected redirect: $(cat "$work/redirect")"
tr -d '\r' <"$work/redirect" | grep -Fx 'server: envoy' >/dev/null ||
  fail "redirect was not served by Envoy: $(cat "$work/redirect")"

# A path without a Mapping is not routed.
code=$(curl --silent --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$http_port/unmapped/")
test "$code" = 404 || fail "unmapped path returned $code, expected 404"

# diagd's internal API is not reachable through the health check port.
code=$(curl --silent --max-time 5 -o /dev/null -w '%{http_code}' -X POST \
  "http://127.0.0.1:$admin_port/_internal/v0/watt")
test "$code" != 200 || fail 'diagd internal API is exposed on the health check port'

# SIGTERM stops the whole process group.
docker stop -t 30 "$emissary" >/dev/null || fail 'could not stop emissary'
test "$(docker inspect --format '{{.State.OOMKilled}}' "$emissary")" = false || fail 'emissary was OOM killed'

printf 'emissary %s (Envoy %s) smoke test passed\n' "$expected_version" "$envoy_version"
