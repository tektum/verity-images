#!/bin/sh
set -eu

# Out-of-cluster behavior that needs no AI backend. A pinned Verity etcd and
# kube-apiserver provide a real API server on a per-test *internal* bridge
# network, so no container in this test can reach the outside world. The
# K8sGPT, Result, and Mutation CRDs are registered, but no custom resources are
# created, so the operator never deploys k8sgpt or calls an AI backend. The
# manager must:
#   - fail fast on unknown flags, without a kubeconfig, and on an unusable
#     metrics bind address;
#   - start its K8sGPT and Mutation controllers against the local API server and
#     serve /healthz, /readyz, and /metrics;
#   - stop cleanly on SIGTERM.

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

etcd_index=ghcr.io/tektum/etcd@sha256:fc322841b20ac374159333e013fb417aa712e776380c53dc34ab8a1958c07fd2
api_index=ghcr.io/tektum/kube-apiserver@sha256:b46742424f608bb186b83390c41cbe7f97df411ae3cf8fc3e4578c096a6b57bd
curl_index='docker.io/curlimages/curl:8.14.1@sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b'

id=$$
label="verity-test=k8sgpt-operator-$id"
network="verity-k8sgpt-$id"
etcd="verity-k8sgpt-etcd-$id"
api="verity-k8sgpt-api-$id"
mgr="verity-k8sgpt-mgr-$id"
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  for c in "$mgr" "$api"; do
    printf -- '--- %s\n' "$c" >&2
    docker logs "$c" 2>&1 | tail -n 30 >&2 || true
  done
  exit 1
}

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] ||
  fail 'unexpected OCI user'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/manager"]' ] ||
  fail 'unexpected entrypoint'

# out NAME ARGS...: run the image under a 60s bound; record status and output.
# A timeout is a failure: every case here must exit on its own.
out() {
  name=$1
  shift
  status=0
  timeout 60 docker run --rm --label "$label" --read-only --cap-drop=ALL "$@" \
    >"$work/$name.out" 2>&1 || status=$?
  [ "$status" != 124 ] || fail "$name: timed out"
}

expect_fail() {
  name=$1
  message=$2
  shift 2
  out "$name" "$@"
  [ "$status" != 0 ] || fail "$name: unexpectedly succeeded"
  grep -qF -- "$message" "$work/$name.out" ||
    fail "$name: missing '$message': $(head -n 8 "$work/$name.out")"
}

# The /manager path is the upstream chart's container command.
out help --network none --entrypoint /manager "$image" --help
[ "$status" = 0 ] || fail "--help exited $status"
for f in -metrics-bind-address -health-probe-bind-address -leader-elect -kubeconfig; do
  grep -qF -- "$f" "$work/help.out" || fail "--help does not list $f"
done

expect_fail unknown-flag 'flag provided but not defined: -no-such-flag' \
  --network none "$image" --no-such-flag
expect_fail no-kubeconfig 'invalid configuration: no configuration has been provided' \
  --network none "$image"

# image_arch, pull_child: resolve each pinned helper index to the candidate's
# platform child, verifying the index bytes against the pin. A classic Docker
# store cannot bind one index digest to a second platform's image.
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
etcd_image=$(pull_child "$etcd_index") || exit 1
api_image=$(pull_child "$api_index") || exit 1
curl_image=$(pull_child "$curl_index") || exit 1

mkdir -p "$work/pki" "$work/kube" "$work/crd"
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

# crd PLURAL SINGULAR KIND: a schemaless stand-in for an upstream CRD. The manager only
# needs the group, version, and kinds to be served for its informers.
crd() {
  cat >"$work/crd/$1.yaml" <<EOF
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: $1.core.k8sgpt.ai
spec:
  group: core.k8sgpt.ai
  scope: Namespaced
  names:
    plural: $1
    singular: $2
    kind: $3
    listKind: ${3}List
  versions:
    - name: v1alpha1
      served: true
      storage: true
      subresources:
        status: {}
      schema:
        openAPIV3Schema:
          type: object
          x-kubernetes-preserve-unknown-fields: true
EOF
}
crd k8sgpts k8sgpt K8sGPT
crd results result Result
crd mutations mutation Mutation
chmod -R a+rX "$work"

# An internal network has no default route, which kube-apiserver needs to pick
# its advertise address. Let Docker choose a free subnet, then recreate the
# network with that subnet declared so the API server can take a fixed address.
docker network create --internal --label "$label" "$network" >/dev/null
subnet=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$network")
docker network rm "$network" >/dev/null
docker network create --internal --subnet "$subnet" --label "$label" "$network" >/dev/null
api_ip=$(printf '%s' "${subnet%/*}" | awk -F. '{ printf "%s.%s.%s.10", $1, $2, $3 }')
docker run -d --label "$label" --name "$etcd" --network "$network" \
  --tmpfs /var/lib/etcd:uid=65532,gid=65532 "$etcd_image" --data-dir=/var/lib/etcd/data \
  --listen-client-urls=http://0.0.0.0:2379 --advertise-client-urls="http://$etcd:2379" >/dev/null ||
  fail 'etcd did not start'
docker run -d --label "$label" --name "$api" --network "$network" --ip "$api_ip" --tmpfs /tmp:uid=65532,gid=65532 \
  -v "$work/pki:/pki:ro" "$api_image" \
  --etcd-servers="http://$etcd:2379" --advertise-address="$api_ip" --secure-port=6443 --cert-dir=/tmp \
  --token-auth-file=/pki/tokens.csv --authorization-mode=RBAC \
  --service-account-issuer=https://kubernetes.default.svc \
  --service-account-key-file=/pki/sa.key --service-account-signing-key-file=/pki/sa.key \
  --service-cluster-ip-range=10.96.0.0/16 >/dev/null || fail 'kube-apiserver did not start'

# api_curl ARGS...: curl the API server as the admin token from the test network.
api_curl() {
  docker run --rm --label "$label" --network "$network" -v "$work/crd:/crd:ro" "$curl_image" \
    -sk --max-time 10 -H "Authorization: Bearer $token" "$@"
}

i=0
until api_curl -f "https://$api:6443/readyz" >/dev/null 2>&1; do
  [ "$(docker inspect -f '{{.State.Running}}' "$api" 2>/dev/null)" = true ] ||
    fail 'kube-apiserver exited before it was ready'
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'kube-apiserver did not become ready'
  sleep 2
done

for plural in k8sgpts results mutations; do
  code=$(api_curl -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/yaml' \
    --data-binary "@/crd/$plural.yaml" \
    "https://$api:6443/apis/apiextensions.k8s.io/v1/customresourcedefinitions") || true
  [ "$code" = 201 ] || fail "creating the $plural CRD returned $code"
done
i=0
until [ "$(api_curl "https://$api:6443/apis/core.k8sgpt.ai/v1alpha1" 2>/dev/null |
  jq -r '[.resources[].name] | sort | join(",")' 2>/dev/null)" = \
  'k8sgpts,k8sgpts/status,mutations,mutations/status,results,results/status' ]; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail 'core.k8sgpt.ai/v1alpha1 was not served'
  sleep 1
done

# An unusable metrics address must stop the manager instead of leaving it
# running without metrics.
expect_fail bad-metrics-address 'problem running manager' --network "$network" \
  -v "$work/kube:/kube:ro" -e KUBECONFIG=/kube/config "$image" \
  --metrics-bind-address=bogus:address:1

# KUBECONFIG serves both controller-runtime and the kubectl-style factory the
# integrations package builds its REST mapper from.
docker run -d --label "$label" --name "$mgr" --network "$network" --read-only --cap-drop=ALL \
  -v "$work/kube:/kube:ro" -e KUBECONFIG=/kube/config "$image" >/dev/null ||
  fail 'manager did not start'

# probe PORT PATH: body, then the HTTP status on the last line.
probe() {
  docker run --rm --label "$label" --network "$network" "$curl_image" -s --max-time 10 \
    -o /dev/stdout -w '\n%{http_code}' "http://$mgr:$1$2" 2>/dev/null || true
}

ready=
i=0
while [ "$i" -lt 45 ]; do
  [ "$(docker inspect -f '{{.State.Running}}' "$mgr" 2>/dev/null)" = true ] ||
    fail "manager exited $(docker inspect -f '{{.State.ExitCode}}' "$mgr" 2>/dev/null)"
  ready=$(probe 8081 /readyz)
  [ "$(printf '%s\n' "$ready" | tail -n 1)" = 200 ] && break
  i=$((i + 1))
  sleep 2
done
[ "$(printf '%s\n' "$ready" | tail -n 1)" = 200 ] || fail "readyz did not return 200: $ready"
[ "$(printf '%s\n' "$ready" | head -n 1)" = ok ] || fail "unexpected readyz body: $ready"
healthz=$(probe 8081 /healthz)
[ "$healthz" = "ok
200" ] || fail "unexpected healthz response: $healthz"

# Both controllers must have started workers against the served CRDs.
i=0
while :; do
  metrics=$(probe 8080 /metrics)
  [ "$(printf '%s\n' "$metrics" | tail -n 1)" = 200 ] || fail 'metrics did not return 200'
  if printf '%s\n' "$metrics" | grep -q '^controller_runtime_active_workers{controller="k8sgpt"} ' &&
    printf '%s\n' "$metrics" | grep -q '^controller_runtime_active_workers{controller="mutation"} '; then
    break
  fi
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail 'metrics do not show the k8sgpt and mutation controllers'
  sleep 2
done
printf '%s\n' "$metrics" | grep -q '^go_info{version="go' || fail 'metrics are missing go_info'

docker logs "$mgr" >"$work/run.log" 2>&1
grep -qF 'Starting workers' "$work/run.log" || fail 'manager did not start its controller workers'
if grep -qE '"level":"error"|	ERROR	' "$work/run.log"; then
  fail "manager logged an error: $(grep -E '"level":"error"|	ERROR	' "$work/run.log" | head -n 1)"
fi

docker stop -t 20 "$mgr" >/dev/null
code=$(docker inspect -f '{{.State.ExitCode}}' "$mgr")
docker logs "$mgr" >"$work/shutdown.log" 2>&1
grep -qF 'Stopping and waiting for non leader election runnables' "$work/shutdown.log" ||
  fail 'manager did not begin a graceful shutdown on SIGTERM'
[ "$code" = 0 ] || fail "manager exited $code on SIGTERM"

printf 'SMOKE PASS version=%s\n' "$expected_version"
