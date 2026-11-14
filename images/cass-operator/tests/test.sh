#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# Peers for a real control plane: Verity etcd 3.7, kube-apiserver 1.37,
# kube-controller-manager 1.37 (StatefulSet controller only) and kubectl 1.35,
# pinned by digest.
etcd_index=ghcr.io/tektum/etcd@sha256:fc322841b20ac374159333e013fb417aa712e776380c53dc34ab8a1958c07fd2
api_index=ghcr.io/tektum/kube-apiserver@sha256:b46742424f608bb186b83390c41cbe7f97df411ae3cf8fc3e4578c096a6b57bd
kcm_index=ghcr.io/tektum/kube-controller-manager@sha256:ec33bd5b9fc4a01f51ddb130154064d867e3966e7f3475154c9ccc302b84a913
kubectl_index=ghcr.io/tektum/kubectl@sha256:537780af388652be3a0130aacd6d1cfed24704ab6a820c6c7024602ec7777332

id=$$
network="verity-cassop-$id"
etcd="verity-cassop-etcd-$id"
api="verity-cassop-api-$id"
kcm="verity-cassop-kcm-$id"
op="verity-cassop-op-$id"
work=$(mktemp -d)
ns=cass-operator

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  for c in "$op" "$kcm" "$api"; do
    printf -- '--- %s\n' "$c" >&2
    docker logs "$c" 2>&1 | tail -n 40 >&2 || true
  done
  exit 1
}

cleanup() {
  docker rm -f "$op" "$kcm" "$api" "$etcd" >/dev/null 2>&1 || true
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
  '["/usr/bin/manager"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = / ||
  fail 'unexpected working directory'

# Upstream runs read-only as 65532 with every capability dropped.
run() {
  docker run --rm --network none --read-only --cap-drop=ALL "$@"
}

# CLI surface: Go flag parsing, as upstream.
run "$image" --help >"$work/help" 2>&1 || fail "help failed: $(cat "$work/help")"
for flag in -health-probe-bind-address -metrics-bind-address -webhook-cert-path \
  -leader-elect -max-concurrent-reconciles -zap-log-level; do
  grep -F -e "$flag" "$work/help" >/dev/null || fail "help is missing $flag"
done
status=0
run "$image" --definitely-invalid >"$work/invalid" 2>&1 || status=$?
test "$status" -eq 2 || fail "invalid flag exited $status, want 2"
grep -F 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"

# Upstream manifests and charts run /manager; that path still runs.
run --entrypoint /manager "$image" --help >/dev/null 2>&1 ||
  fail 'compatibility path /manager does not run'

# Without any cluster configuration the manager refuses to start.
status=0
run "$image" >"$work/nocluster" 2>&1 || status=$?
test "$status" -ne 0 || fail 'manager outside a cluster unexpectedly succeeded'
grep -F 'KUBERNETES_SERVICE_HOST and KUBERNETES_SERVICE_PORT must be defined' "$work/nocluster" \
  >/dev/null || fail "in-cluster diagnostic is missing: $(cat "$work/nocluster")"

# The image ships the CRDs generated for this build; install exactly those.
mkdir -p "$work/crds"
holder=$(docker create "$image") || fail 'could not create a container to copy the CRDs'
docker cp "$holder:/usr/share/cass-operator/crds/." "$work/crds/" >/dev/null 2>&1 ||
  { docker rm "$holder" >/dev/null; fail 'image does not ship /usr/share/cass-operator/crds'; }
docker rm "$holder" >/dev/null
for crd in cassandra.datastax.com_cassandradatacenters control.k8ssandra.io_cassandratasks \
  control.k8ssandra.io_scheduledtasks; do
  [ -s "$work/crds/$crd.yaml" ] || fail "missing CRD $crd.yaml"
done
chmod -R a+rX "$work/crds"

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
kcm_image=$(pull_child "$kcm_index")
kubectl_image=$(pull_child "$kubectl_index")

# Control plane: etcd, kube-apiserver with a static admin token, and the
# controller manager running only the StatefulSet controller. No scheduler or
# kubelet runs, so Cassandra pods are created but never start.
mkdir -p "$work/pki" "$work/kube" "$work/sa"
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
chmod 0644 "$work/kube/config"
# Out of cluster the operator still reads its own namespace from the service
# account mount; the image config ConfigMap is looked up there.
printf '%s' "$ns" >"$work/sa/namespace"
chmod 0755 "$work/sa"
chmod 0644 "$work/sa/namespace"

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
  docker run --rm -i --network "$network" -v "$work/kube:/kube:ro" -v "$work/crds:/crds:ro" \
    -e KUBECONFIG=/kube/config "$kubectl_image" "$@"
}

i=0
until kubectl get --raw /readyz >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'kube-apiserver did not become ready'
  sleep 2
done

docker run -d --name "$kcm" --network "$network" --tmpfs /tmp:uid=65532,gid=65532 \
  -v "$work/kube:/kube:ro" "$kcm_image" \
  --kubeconfig=/kube/config --authentication-kubeconfig=/kube/config \
  --authorization-kubeconfig=/kube/config --cert-dir=/tmp --leader-elect=false \
  --controllers=statefulset >/dev/null

# The DatacenterCRD exceeds the client-side apply annotation limit.
kubectl create -f /crds >"$work/crd" 2>&1 || fail "could not create the CRDs: $(cat "$work/crd")"
kubectl wait --for=condition=Established --timeout=60s \
  crd/cassandradatacenters.cassandra.datastax.com crd/cassandratasks.control.k8ssandra.io \
  crd/scheduledtasks.control.k8ssandra.io >"$work/established" 2>&1 ||
  fail "CRDs not established: $(cat "$work/established")"

# The image config is upstream's config/imageconfig/image_config.yaml, which
# upstream's kustomization deploys as this labeled ConfigMap.
kubectl apply -f - >"$work/apply" 2>&1 <<EOF || fail "could not create fixtures: $(cat "$work/apply")"
apiVersion: v1
kind: Namespace
metadata:
  name: $ns
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
  namespace: $ns
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: image-config
  namespace: $ns
  labels:
    k8ssandra.io/config: image
data:
  image_config.yaml: |
    apiVersion: config.k8ssandra.io/v1beta2
    kind: ImageConfig
    metadata:
      name: image-config
    images:
      system-logger:
        repository: k8ssandra
        name: system-logger
        tag: v$expected_version
      config-builder:
        repository: datastax
        name: cass-config-builder
        tag: 1.0-ubi
      k8ssandra-client:
        repository: k8ssandra
        name: k8ssandra-client
        tag: v0.9.2
    defaults:
      registry: ghcr.io
      pullPolicy: IfNotPresent
    types:
      cassandra:
        repository: k8ssandra
        name: cass-management-api
        suffix: -ubi
---
apiVersion: v1
kind: Secret
metadata:
  name: incomplete-superuser
  namespace: $ns
stringData:
  username: admin
EOF

# Out of cluster with a kubeconfig, as upstream's deployment runs it: read-only
# root, no capabilities, leader election, one watched namespace, and no
# --webhook-cert-path so the admission webhooks stay disabled.
docker run -d --name "$op" --network "$network" --read-only --cap-drop=ALL \
  -p 127.0.0.1::8081 -p 127.0.0.1::8080 \
  -v "$work/kube:/kube:ro" -v "$work/sa:/var/run/secrets/kubernetes.io/serviceaccount:ro" \
  -e KUBECONFIG=/kube/config -e WATCH_NAMESPACE="$ns" \
  "$image" --leader-elect --health-probe-bind-address=:8081 \
  --metrics-bind-address=:8080 --metrics-secure=false >/dev/null

probe=$(docker port "$op" 8081/tcp | head -n 1)
metrics=$(docker port "$op" 8080/tcp | head -n 1)
[ -n "$probe" ] && [ -n "$metrics" ] || fail 'probe or metrics port is not published'
i=0
until curl -fsS "http://$probe/readyz" >"$work/readyz" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'operator did not become ready'
  sleep 2
done
test "$(cat "$work/readyz")" = ok || fail "unexpected readyz body: $(cat "$work/readyz")"
curl -fsS "http://$probe/healthz" >"$work/healthz" || fail 'healthz failed'
test "$(cat "$work/healthz")" = ok || fail "unexpected healthz body: $(cat "$work/healthz")"

docker logs "$op" >"$work/oplog" 2>&1
for line in 'webhooks disabled because --webhook-cert-path was not provided' \
  "watch namespace configured"; do
  grep -F "$line" "$work/oplog" >/dev/null || fail "operator log is missing: $line"
done

i=0
until kubectl get lease -n "$ns" b569adb7.cassandra.datastax.com \
  -o 'jsonpath={.spec.holderIdentity}' >"$work/holder" 2>/dev/null && [ -s "$work/holder" ]; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail 'operator did not acquire its leader election lease'
  sleep 2
done

# The CRD schema shipped in the image rejects a malformed server version.
status=0
kubectl apply -f - >"$work/badversion" 2>&1 <<EOF || status=$?
apiVersion: cassandra.datastax.com/v1beta1
kind: CassandraDatacenter
metadata:
  name: badversion
  namespace: $ns
spec:
  clusterName: verity
  serverType: cassandra
  serverVersion: banana
  size: 1
  storageConfig:
    cassandraDataVolumeClaimSpec:
      accessModes: [ReadWriteOnce]
      resources:
        requests:
          storage: 1Gi
EOF
test "$status" -ne 0 || fail 'a malformed serverVersion was accepted'
grep -F 'spec.serverVersion' "$work/badversion" >/dev/null ||
  fail "serverVersion rejection is missing: $(cat "$work/badversion")"

kubectl apply -f - >"$work/dc" 2>&1 <<EOF || fail "could not create the datacenters: $(cat "$work/dc")"
apiVersion: cassandra.datastax.com/v1beta1
kind: CassandraDatacenter
metadata:
  name: dc1
  namespace: $ns
spec:
  clusterName: verity
  serverType: cassandra
  serverVersion: 4.1.8
  size: 1
  storageConfig:
    cassandraDataVolumeClaimSpec:
      accessModes: [ReadWriteOnce]
      resources:
        requests:
          storage: 1Gi
---
apiVersion: cassandra.datastax.com/v1beta1
kind: CassandraDatacenter
metadata:
  name: invalid
  namespace: $ns
spec:
  clusterName: broken
  serverType: cassandra
  serverVersion: 4.1.8
  size: 1
  superuserSecretName: incomplete-superuser
  storageConfig:
    cassandraDataVolumeClaimSpec:
      accessModes: [ReadWriteOnce]
      resources:
        requests:
          storage: 1Gi
EOF

# wait_for DESCRIPTION KUBECTL-ARGS...: poll until the command prints output.
wait_for() {
  what=$1
  shift
  i=0
  until kubectl "$@" >"$work/out" 2>/dev/null && [ -s "$work/out" ]; do
    i=$((i + 1))
    [ "$i" -lt 60 ] || fail "timed out waiting for $what"
    sleep 2
  done
}

sts=verity-dc1-default-sts
wait_for 'the StatefulSet' get statefulset -n "$ns" "$sts" -o name
kubectl get statefulset -n "$ns" "$sts" -o json >"$work/sts.json"
jq -e --arg v "$expected_version" '
  .spec.serviceName == "verity-dc1-all-pods-service"
  and .spec.replicas == 1
  and .metadata.labels["app.kubernetes.io/managed-by"] == "cass-operator"
  and .metadata.labels["cassandra.datastax.com/datacenter"] == "dc1"
  and (.metadata.ownerReferences[0].kind == "CassandraDatacenter")
  and ([.spec.template.spec.containers[] | select(.name == "cassandra") | .image]
       == ["ghcr.io/k8ssandra/cass-management-api:4.1.8-ubi"])
  and ([.spec.template.spec.containers[] | select(.name == "server-system-logger") | .image]
       == ["ghcr.io/k8ssandra/system-logger:v" + $v])
  and (.spec.volumeClaimTemplates[0].spec.resources.requests.storage == "1Gi")
' "$work/sts.json" >/dev/null || fail "unexpected StatefulSet: $(jq -c '{spec: .spec.serviceName, replicas: .spec.replicas, images: [.spec.template.spec.containers[].image]}' "$work/sts.json")"

for svc in verity-dc1-service verity-seed-service verity-dc1-all-pods-service \
  verity-dc1-additional-seed-service; do
  wait_for "service $svc" get service -n "$ns" "$svc" -o name
done
kubectl get service -n "$ns" verity-dc1-service -o 'jsonpath={.spec.clusterIP}' >"$work/clusterip"
test "$(cat "$work/clusterip")" = None || fail 'the datacenter service is not headless'

# The StatefulSet controller creates the pod from the operator's template.
wait_for 'the Cassandra pod' get pod -n "$ns" "$sts-0" -o name

wait_for 'the superuser secret' get secret -n "$ns" verity-superuser -o 'jsonpath={.data.password}'
kubectl get secret -n "$ns" verity-superuser -o 'jsonpath={.data.username}' >"$work/user"
test "$(base64 -d <"$work/user")" = verity-superuser || fail 'unexpected superuser name'

wait_for 'datacenter status' get cassandradatacenter -n "$ns" dc1 \
  -o 'jsonpath={.status.cassandraOperatorProgress}'
test "$(cat "$work/out")" = Updating || fail "unexpected progress: $(cat "$work/out")"

# Stopping the datacenter needs no running Cassandra: the operator scales the
# rack to zero, reports Stopped, and goes on to create the disruption budget.
kubectl patch cassandradatacenter -n "$ns" dc1 --type=merge -p '{"spec":{"stopped":true}}' \
  >/dev/null || fail 'could not stop the datacenter'
i=0
until kubectl get statefulset -n "$ns" "$sts" -o 'jsonpath={.spec.replicas}' >"$work/replicas" 2>/dev/null &&
  [ "$(cat "$work/replicas")" = 0 ]; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'the stopped datacenter was not scaled to zero'
  sleep 2
done
wait_for 'the PodDisruptionBudget' get poddisruptionbudget -n "$ns" dc1-pdb -o 'jsonpath={.spec.minAvailable}'
test "$(cat "$work/out")" = 0 || fail "unexpected PDB minAvailable: $(cat "$work/out")"
wait_for 'the Stopped condition' get cassandradatacenter -n "$ns" dc1 \
  -o 'jsonpath={.status.conditions[?(@.type=="Stopped")].status}'
test "$(cat "$work/out")" = True || fail "unexpected Stopped condition: $(cat "$work/out")"

# The operator records events through the events.k8s.io recorder: the
# machine-readable constant is the action and the human-readable text is the
# reason.
kubectl get events -n "$ns" -o json >"$work/events.json"
for expected in 'CreatedResource|Created statefulset verity-dc1-default-sts' \
  'CreatedResource|Created service verity-dc1-service' \
  'CreatedResource|Created service verity-seed-service' \
  'CreatedResource|Created PodDisruptionBudget dc1-pdb' \
  'StoppingDatacenter|Stopping datacenter'; do
  jq -e --arg a "${expected%%|*}" --arg r "${expected#*|}" '[.items[]
    | select(.involvedObject.name == "dc1" and .action == $a and .reason == $r)] | length > 0' \
    "$work/events.json" >/dev/null ||
    fail "no '$expected' event for dc1: $(jq -c '[.items[] | select(.involvedObject.name == "dc1") | .action + "|" + .reason] | unique' "$work/events.json")"
done

# The operator itself rejects a datacenter whose superuser secret lacks a key.
jq -e '[.items[] | select(.involvedObject.name == "invalid" and .type == "Warning"
  and .action == "ValidationFailed" and (.reason | contains("Missing key: password")))]
  | length > 0' "$work/events.json" >/dev/null ||
  fail "no ValidationFailed event for the invalid datacenter: $(jq -c '[.items[] | select(.involvedObject.name == "invalid") | .action + "|" + .reason]' "$work/events.json")"
if kubectl get statefulset -n "$ns" broken-invalid-default-sts -o name >/dev/null 2>&1; then
  fail 'the invalid datacenter was reconciled'
fi

curl -fsS "http://$metrics/metrics" >"$work/metrics" || fail 'metrics endpoint failed'
grep -E '^controller_runtime_reconcile_total\{controller="cassandradatacenter[^"]*",result="success"\} [1-9]' \
  "$work/metrics" >/dev/null || fail "no successful datacenter reconciles in metrics: $(grep controller_runtime_reconcile_total "$work/metrics")"

# SIGTERM shuts the manager down cleanly.
docker stop --time 20 "$op" >/dev/null || fail 'could not stop the operator'
test "$(docker inspect --format '{{.State.ExitCode}}' "$op")" = 0 ||
  fail "operator exited $(docker inspect --format '{{.State.ExitCode}}' "$op") on SIGTERM"

echo "cass-operator $expected_version: OK"
