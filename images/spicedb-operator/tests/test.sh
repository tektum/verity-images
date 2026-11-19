#!/bin/sh
set -eu

# A pinned Verity etcd and kube-apiserver provide a real API server on a
# per-test *internal* bridge network, so no container in this test can reach
# the outside world. The operator must:
#   - report the pinned version and list its commands and flags;
#   - fail fast on unknown flags and, without a kubeconfig, on the CRD
#     bootstrap against the unreachable client-go default server;
#   - install its SpiceDBCluster CRD, serve /healthz, and reconcile a
#     SpiceDBCluster: without an update graph (none ships in the image, as
#     upstream) it reports the missing base image, and with one mounted at
#     /opt/operator (the upstream manifests' path) it creates the SpiceDB
#     Deployment for the graph's head release;
#   - stop cleanly on SIGTERM.

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

etcd_index=ghcr.io/tektum/etcd@sha256:fc322841b20ac374159333e013fb417aa712e776380c53dc34ab8a1958c07fd2
api_index=ghcr.io/tektum/kube-apiserver@sha256:b46742424f608bb186b83390c41cbe7f97df411ae3cf8fc3e4578c096a6b57bd
curl_index='docker.io/curlimages/curl:8.14.1@sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b'

id=$$
label="verity-test=spicedb-operator-$id"
network="verity-spicedb-operator-$id"
etcd="verity-spicedb-operator-etcd-$id"
api="verity-spicedb-operator-api-$id"
op="verity-spicedb-operator-op-$id"
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  for c in "$op" "$api"; do
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

expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'

# OCI contract.
[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532:65532 ] ||
  fail 'image user is not 65532:65532'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/spicedb-operator"]' ] ||
  fail 'unexpected image entrypoint'
if docker run --rm --network none --entrypoint /bin/sh "$image" -c true >/dev/null 2>&1; then
  fail 'image unexpectedly contains /bin/sh'
fi

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

# Version: the binary reports the pinned upstream release, as upstream does.
out version --network none "$image" version
[ "$status" = 0 ] || fail "version exited $status"
[ "$(cat "$work/version.out")" = "spicedb-operator v$expected_version" ] ||
  fail "unexpected version output: $(cat "$work/version.out")"
out version-deps --network none "$image" version --include-deps
[ "$status" = 0 ] || fail "version --include-deps exited $status"
[ "$(head -n 1 "$work/version-deps.out")" = "github.com/authzed/spicedb-operator/cmd/spicedb-operator v$expected_version" ] ||
  fail "unexpected version --include-deps output: $(head -n 1 "$work/version-deps.out")"
grep -qF 'k8s.io/client-go v' "$work/version-deps.out" ||
  fail 'version --include-deps does not list client-go'

out help --network none "$image" --help
[ "$status" = 0 ] || fail "--help exited $status"
for c in 'run         run SpiceDB operator' 'version     display operator version information'; do
  grep -qF -- "$c" "$work/help.out" || fail "--help does not list '$c'"
done
out run-help --network none "$image" run --help
[ "$status" = 0 ] || fail "run --help exited $status"
for f in --config --crd --kubeconfig --debug-address --watch-namespaces --base-image; do
  grep -qF -- "$f " "$work/run-help.out" || fail "run --help does not list $f"
done

expect_fail unknown-flag 'unknown flag: --no-such-flag' --network none "$image" run --no-such-flag

# Out of cluster with no kubeconfig, client-go falls back to localhost:8080 and
# the default CRD bootstrap fails fast instead of hanging.
expect_fail no-kubeconfig 'failed when fetching CRD "spicedbclusters.authzed.com"' \
  --network none "$image" run
grep -qF 'localhost:8080' "$work/no-kubeconfig.out" ||
  fail "no-kubeconfig: unexpected target: $(head -n 3 "$work/no-kubeconfig.out")"
if grep -qF 'panic:' "$work/no-kubeconfig.out"; then
  fail 'no-kubeconfig: operator panicked'
fi

# pull_child INDEX: resolve a pinned helper index to the candidate's platform
# child, verifying the index bytes against the pin. A classic Docker store
# cannot bind one index digest to a second platform's image.
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

mkdir -p "$work/pki" "$work/kube" "$work/opt" "$work/obj"
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
# A minimal update graph in the upstream format: a memory-datastore channel
# whose head is the SpiceDB release the operator must deploy.
cat >"$work/opt/config.yaml" <<'EOF'
imageName: ghcr.io/authzed/spicedb
channels:
  - name: stable
    metadata:
      datastore: memory
      default: "true"
    nodes:
      - id: v1.57.1
        tag: v1.57.1
      - id: v1.56.2
        tag: v1.56.2
    edges:
      v1.56.2:
        - v1.57.1
EOF
cat >"$work/obj/secret.json" <<'EOF'
{"apiVersion":"v1","kind":"Secret","metadata":{"name":"smoke","namespace":"default"},
 "stringData":{"preshared_key":"verity-smoke-only"}}
EOF
cat >"$work/obj/cluster.json" <<'EOF'
{"apiVersion":"authzed.com/v1alpha1","kind":"SpiceDBCluster",
 "metadata":{"name":"smoke","namespace":"default"},
 "spec":{"config":{"datastoreEngine":"memory"},"secretName":"smoke"}}
EOF
chmod -R a+rX "$work"

# An internal network has no default route, so kube-apiserver gets an explicit
# loopback advertise address and no endpoint reconciler; the operator reaches
# it through the kubeconfig, not the in-cluster kubernetes Service.
docker network create --internal --label "$label" "$network" >/dev/null
docker run -d --label "$label" --name "$etcd" --network "$network" \
  --tmpfs /var/lib/etcd:uid=65532,gid=65532 "$etcd_image" --data-dir=/var/lib/etcd/data \
  --listen-client-urls=http://0.0.0.0:2379 --advertise-client-urls="http://$etcd:2379" >/dev/null ||
  fail 'etcd did not start'
docker run -d --label "$label" --name "$api" --network "$network" --tmpfs /tmp:uid=65532,gid=65532 \
  -v "$work/pki:/pki:ro" "$api_image" \
  --etcd-servers="http://$etcd:2379" --secure-port=6443 --cert-dir=/tmp \
  --advertise-address=127.0.0.1 --endpoint-reconciler-type=none \
  --token-auth-file=/pki/tokens.csv --authorization-mode=RBAC \
  --service-account-issuer=https://kubernetes.default.svc \
  --service-account-key-file=/pki/sa.key --service-account-signing-key-file=/pki/sa.key \
  --service-cluster-ip-range=10.96.0.0/16 >/dev/null || fail 'kube-apiserver did not start'

# kube ARGS...: curl the API server as the admin token from the test network.
kube() {
  docker run --rm --label "$label" --network "$network" -v "$work/obj:/obj:ro" "$curl_image" \
    -sk --max-time 10 -H "Authorization: Bearer $token" "$@"
}

i=0
until kube -f "https://$api:6443/readyz" >/dev/null 2>&1; do
  [ "$(docker inspect -f '{{.State.Running}}' "$api" 2>/dev/null)" = true ] ||
    fail 'kube-apiserver exited before it was ready'
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'kube-apiserver did not become ready'
  sleep 2
done
i=0
until [ "$(kube -o /dev/null -w '%{http_code}' "https://$api:6443/api/v1/namespaces/default")" = 200 ]; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail 'the default namespace was not created'
  sleep 1
done
crd_url="https://$api:6443/apis/apiextensions.k8s.io/v1/customresourcedefinitions/spicedbclusters.authzed.com"
[ "$(kube -o /dev/null -w '%{http_code}' "$crd_url")" = 404 ] ||
  fail 'the SpiceDBCluster CRD exists before the operator ran'

# start_op ARGS...: run the operator with the upstream securityContext
# (read-only root, no capabilities) and wait for /healthz.
start_op() {
  docker run -d --label "$label" --name "$op" --network "$network" --read-only --cap-drop=ALL \
    -v "$work/kube:/kube:ro" -v "$work/opt:/opt/operator:ro" -e KUBECONFIG=/kube/config \
    "$image" run "$@" >/dev/null || fail 'operator did not start'
  i=0
  until [ "$(docker run --rm --label "$label" --network "$network" "$curl_image" -s --max-time 5 \
    -o /dev/null -w '%{http_code}' "http://$op:8080/healthz" 2>/dev/null)" = 200 ]; do
    [ "$(docker inspect -f '{{.State.Running}}' "$op" 2>/dev/null)" = true ] ||
      fail "operator exited $(docker inspect -f '{{.State.ExitCode}}' "$op" 2>/dev/null)"
    i=$((i + 1))
    [ "$i" -lt 45 ] || fail 'operator /healthz did not return 200'
    sleep 2
  done
}

# stop_op: SIGTERM must stop the operator with status 0.
stop_op() {
  docker stop -t 20 "$op" >/dev/null || fail 'cannot stop the operator'
  code=$(docker inspect -f '{{.State.ExitCode}}' "$op")
  docker logs "$op" >"$work/$1.log" 2>&1
  docker rm "$op" >/dev/null
  [ "$code" = 0 ] || fail "operator exited $code on SIGTERM"
  if grep -qF 'panic:' "$work/$1.log"; then
    fail "operator panicked: $(grep -F 'panic:' "$work/$1.log" | head -n 1)"
  fi
}

# status_matches FILTER: poll the SpiceDBCluster until the jq filter is true.
status_matches() {
  i=0
  until kube "https://$api:6443/apis/authzed.com/v1alpha1/namespaces/default/spicedbclusters/smoke" |
    jq -e "$1" >/dev/null 2>&1; do
    [ "$(docker inspect -f '{{.State.Running}}' "$op" 2>/dev/null)" = true ] ||
      fail 'operator exited while reconciling'
    i=$((i + 1))
    [ "$i" -lt 45 ] || fail "SpiceDBCluster status never matched $1: $(kube \
      "https://$api:6443/apis/authzed.com/v1alpha1/namespaces/default/spicedbclusters/smoke" | jq -c .status)"
    sleep 2
  done
}

# Run 1: the image as shipped, with the default CRD bootstrap and no graph.
start_op -v=4

uid=$(docker top "$op" -o pid,uid,comm | awk '$3 == "spicedb-operato" || $3 == "spicedb-operator" { print $2 }')
[ "$uid" = 65532 ] || fail "operator process uid is '$uid', want 65532"

kube "$crd_url" | jq -e '
  .spec.group == "authzed.com" and .spec.names.kind == "SpiceDBCluster" and
  any(.status.conditions[]; .type == "Established" and .status == "True")' >/dev/null ||
  fail 'the operator did not install an established SpiceDBCluster CRD'
[ "$(kube "https://$api:6443/apis/authzed.com/v1alpha1" | jq -r '[.resources[].name] | sort | join(",")')" = \
  'spicedbclusters,spicedbclusters/status' ] || fail 'authzed.com/v1alpha1 is not served'

metrics=$(docker run --rm --label "$label" --network "$network" "$curl_image" -sf --max-time 10 \
  "http://$op:8080/metrics") || fail '/metrics did not return 200'
printf '%s\n' "$metrics" | grep -q '^go_info{version="go' || fail '/metrics is missing go_info'

for obj in secret:/api/v1/namespaces/default/secrets \
  cluster:/apis/authzed.com/v1alpha1/namespaces/default/spicedbclusters; do
  code=$(kube -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    --data-binary "@/obj/${obj%%:*}.json" "https://$api:6443${obj#*:}") || true
  [ "$code" = 201 ] || fail "creating the ${obj%%:*} returned $code"
done

# The controller validates the cluster and reports that nothing tells it which
# SpiceDB image to run.
status_matches 'any(.status.conditions[]?; .type == "ValidatingFailed" and .reason == "InvalidConfig"
  and (.message | contains("no base image specified")))'
kube "https://$api:6443/apis/apps/v1/namespaces/default/deployments" |
  jq -e '.kind == "DeploymentList" and (.items | length) == 0' >/dev/null ||
  fail 'a Deployment was created without an image'
stop_op run-default

# Run 2: with an update graph mounted where the upstream manifests mount it, the
# controller resolves the channel head and creates the SpiceDB Deployment.
start_op -v=4 --crd=false --config /opt/operator/config.yaml
status_matches '.status.image == "ghcr.io/authzed/spicedb:v1.57.1" and
  .status.version.channel == "stable" and .status.version.name == "v1.57.1"'
i=0
until kube "https://$api:6443/apis/apps/v1/namespaces/default/deployments/smoke-spicedb" | jq -e '
  .spec.template.spec.containers[0].image == "ghcr.io/authzed/spicedb:v1.57.1" and
  .metadata.ownerReferences[0].kind == "SpiceDBCluster"' >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail 'the operator did not create the smoke-spicedb Deployment'
  sleep 2
done
stop_op run-graph
grep -qF 'controller="spicedbclusters"' "$work/run-graph.log" ||
  fail 'operator logs show no spicedbclusters controller activity'

printf 'SMOKE PASS version=%s\n' "$expected_version"
