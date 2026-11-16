#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# Peers for a real control plane: Verity etcd 3.7, kube-apiserver 1.37 and
# kubectl 1.35, pinned by digest. No scheduler or kubelet runs, so Postgres
# pods are never created; the operator's own objects are what is asserted.
etcd_index=ghcr.io/tektum/etcd@sha256:fc322841b20ac374159333e013fb417aa712e776380c53dc34ab8a1958c07fd2
api_index=ghcr.io/tektum/kube-apiserver@sha256:b46742424f608bb186b83390c41cbe7f97df411ae3cf8fc3e4578c096a6b57bd
kubectl_index=ghcr.io/tektum/kubectl@sha256:537780af388652be3a0130aacd6d1cfed24704ab6a820c6c7024602ec7777332

id=$$
network="verity-pgo-$id"
etcd="verity-pgo-etcd-$id"
api="verity-pgo-api-$id"
op="verity-pgo-op-$id"
work=$(mktemp -d)
ns=pgo
cluster=acid-verity

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  for c in "$op" "$api"; do
    printf -- '--- %s\n' "$c" >&2
    docker logs "$c" 2>&1 | tail -n 60 >&2 || true
  done
  exit 1
}

cleanup() {
  docker rm -f "$op" "$api" "$etcd" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/postgres-operator"]' || fail 'unexpected entrypoint'

run() {
  docker run --rm --network none --read-only --cap-drop=ALL "$@"
}

# CLI surface: Go flag parsing, as upstream.
run "$image" --help >"$work/help" 2>&1 || fail "help failed: $(cat "$work/help")"
for flag in -kubeconfig -outofcluster -nodatabaseaccess -noteamsapi -kubeqps -kubeburst; do
  grep -F -e "$flag" "$work/help" >/dev/null || fail "help is missing $flag"
done
status=0
run "$image" --definitely-invalid >"$work/invalid" 2>&1 || status=$?
test "$status" -eq 2 || fail "invalid flag exited $status, want 2"
grep -F 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"

# pull_child INDEX: pull the pinned index by its per-platform child digest,
# verifying the index bytes against the pin first so the pin stays authoritative.
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

mkdir -p "$work/pki" "$work/kube"
openssl genrsa -out "$work/pki/sa.key" 2048 2>/dev/null || fail 'could not generate the service account key'
token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
printf '%s,verity-admin,verity-admin,system:masters\n' "$token" >"$work/pki/tokens.csv"
chmod 0644 "$work/pki/sa.key" "$work/pki/tokens.csv"
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
chmod 0755 "$work/kube"
chmod 0644 "$work/kube/config"

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
  docker run --rm -i --network "$network" -v "$work/kube:/kube:ro" \
    -e KUBECONFIG=/kube/config "$kubectl_image" "$@"
}

i=0
until kubectl get --raw /readyz >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'kube-apiserver did not become ready'
  sleep 2
done

# Operator configuration as upstream's manifests/configmap.yaml shape.
kubectl apply -f - >"$work/apply" 2>&1 <<EOF || fail "could not create fixtures: $(cat "$work/apply")"
apiVersion: v1
kind: Namespace
metadata:
  name: $ns
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: postgres-operator
  namespace: $ns
data:
  watched_namespace: $ns
  api_port: "8080"
  cluster_labels: application:spilo
  cluster_name_label: cluster-name
  enable_teams_api: "false"
  resync_period: 30s
  repair_period: 30s
  workers: "2"
EOF

# Out of cluster with a kubeconfig, read-only root, no capabilities, and no
# database or teams API access since no Postgres pod can ever run here.
# Upstream 2.0.3 creates its CRD on a fresh cluster and then exits fatally
# (createOperatorCRD updates the empty object returned by the failed Get); the
# Deployment's restart is what brings it up, so restart it the same way.
docker run -d --name "$op" --network "$network" --read-only --cap-drop=ALL \
  --restart=on-failure:5 \
  -p 127.0.0.1::8080 -v "$work/kube:/kube:ro" \
  -e CONFIG_MAP_NAME="$ns/postgres-operator" -e OPERATOR_NAMESPACE="$ns" \
  "$image" --kubeconfig=/kube/config --outofcluster --nodatabaseaccess --noteamsapi >/dev/null

# The operator registers its own CRDs on startup.
i=0
until kubectl get crd postgresqls.acid.zalan.do >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'operator did not register the postgresql CRD'
  sleep 2
done
kubectl wait --for=condition=Established --timeout=60s crd/postgresqls.acid.zalan.do \
  >"$work/established" 2>&1 || fail "CRD not established: $(cat "$work/established")"
kubectl get crd postgresqls.acid.zalan.do -o 'jsonpath={.spec.group}/{.spec.names.kind}' \
  >"$work/crd" 2>&1 || fail 'could not read the CRD'
test "$(cat "$work/crd")" = acid.zalan.do/postgresql || fail "unexpected CRD: $(cat "$work/crd")"

docker logs "$op" >"$work/oplog" 2>&1
grep -F "Spilo operator v$expected_version" "$work/oplog" >/dev/null ||
  fail "operator log does not report version v$expected_version"

# The OpenAPI schema registered by the operator rejects a malformed manifest.
status=0
kubectl apply -f - >"$work/bad" 2>&1 <<EOF || status=$?
apiVersion: acid.zalan.do/v1
kind: postgresql
metadata:
  name: acid-bad
  namespace: $ns
spec:
  teamId: acid
  numberOfInstances: 1
  volume:
    size: banana
  postgresql:
    version: "17"
EOF
test "$status" -ne 0 || fail 'malformed postgresql was accepted'
grep -F 'spec.volume.size' "$work/bad" >/dev/null || fail "unexpected rejection: $(cat "$work/bad")"

kubectl apply -f - >"$work/pg" 2>&1 <<EOF || fail "could not create the postgresql: $(cat "$work/pg")"
apiVersion: acid.zalan.do/v1
kind: postgresql
metadata:
  name: $cluster
  namespace: $ns
spec:
  teamId: acid
  numberOfInstances: 2
  volume:
    size: 1Gi
  users:
    verity: [superuser, createdb]
  databases:
    verity: verity
  postgresql:
    version: "17"
EOF

# Reconciliation turns the postgresql into a StatefulSet, Services and Secrets.
i=0
until kubectl get statefulset -n "$ns" "$cluster" >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'operator did not create the StatefulSet'
  sleep 2
done
kubectl get statefulset -n "$ns" "$cluster" \
  -o 'jsonpath={.spec.replicas} {.metadata.labels.cluster-name} {.metadata.labels.application} {.spec.template.spec.containers[0].name}' \
  >"$work/sts" 2>&1 || fail 'could not read the StatefulSet'
test "$(cat "$work/sts")" = "2 $cluster spilo postgres" || fail "unexpected StatefulSet: $(cat "$work/sts")"
kubectl get statefulset -n "$ns" "$cluster" \
  -o 'jsonpath={.spec.volumeClaimTemplates[0].spec.resources.requests.storage}' >"$work/pvc" 2>&1 ||
  fail 'could not read the volume claim template'
test "$(cat "$work/pvc")" = 1Gi || fail "unexpected volume size: $(cat "$work/pvc")"

for svc in "$cluster" "$cluster-repl"; do
  i=0
  until kubectl get service -n "$ns" "$svc" >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -lt 30 ] || fail "operator did not create service $svc"
    sleep 2
  done
done
kubectl get service -n "$ns" "$cluster" -o 'jsonpath={.spec.ports[0].port}' >"$work/port" 2>&1 ||
  fail 'could not read the master service'
test "$(cat "$work/port")" = 5432 || fail "unexpected service port: $(cat "$work/port")"

for user in postgres standby verity; do
  secret="$user.$cluster.credentials.postgresql.acid.zalan.do"
  i=0
  until kubectl get secret -n "$ns" "$secret" -o 'jsonpath={.data.username}' >"$work/user" 2>/dev/null &&
    [ -s "$work/user" ]; do
    i=$((i + 1))
    [ "$i" -lt 30 ] || fail "operator did not create secret $secret"
    sleep 2
  done
  test "$(base64 -d <"$work/user")" = "$user" || fail "unexpected username in $secret"
  kubectl get secret -n "$ns" "$secret" -o 'jsonpath={.data.password}' >"$work/pw" 2>&1 ||
    fail "could not read the password of $secret"
  test "$(base64 -d <"$work/pw" | wc -c)" -ge 32 || fail "weak password in $secret"
done

# The operator's REST API reports the cluster it now manages.
port=$(docker port "$op" 8080/tcp | head -n 1)
[ -n "$port" ] || fail 'operator API port is not published'
curl -fsS "http://$port/clusters/" >"$work/clusters" || fail 'operator API did not answer'
grep -F "$cluster" "$work/clusters" >/dev/null || fail "operator API does not list $cluster: $(cat "$work/clusters")"

status_value=$(kubectl get postgresql -n "$ns" "$cluster" -o 'jsonpath={.status.PostgresClusterStatus}')
case "$status_value" in
  Creating | Running | *Failed) ;;
  *) fail "unexpected postgresql status: $status_value" ;;
esac

printf 'SMOKE PASS image=%s\n' "$image"
