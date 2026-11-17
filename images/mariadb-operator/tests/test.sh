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
network="verity-mdbop-$id"
etcd="verity-mdbop-etcd-$id"
api="verity-mdbop-api-$id"
op="verity-mdbop-op-$id"
work=$(mktemp -d)
ns=mariadb-operator
mariadb_image=docker-registry1.mariadb.com/library/mariadb:12.3.3

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  for c in "$op" "$api"; do
    printf -- '--- %s\n' "$c" >&2
    docker logs "$c" 2>&1 | tail -n 40 >&2 || true
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
  '["/bin/mariadb-operator"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = / ||
  fail 'unexpected working directory'

# Upstream's chart runs the operator read-only as 65532 with every capability
# dropped.
run() {
  docker run --rm --network none --read-only --cap-drop=ALL "$@"
}

# CLI surface: cobra commands, as upstream. The operator starts its backup,
# init, and agent containers from this image by subcommand.
run "$image" --help >"$work/help" 2>&1 || fail "help failed: $(cat "$work/help")"
for cmd in agent backup cert-controller init pitr webhook; do
  grep -E "^  $cmd " "$work/help" >/dev/null || fail "help is missing the $cmd command"
done
for flag in --health-addr --metrics-addr --leader-elect --webhook --log-level; do
  grep -F -e "$flag" "$work/help" >/dev/null || fail "help is missing $flag"
done
for cmd in backup init webhook cert-controller; do
  run "$image" "$cmd" --help >"$work/sub" 2>&1 || fail "$cmd --help failed: $(cat "$work/sub")"
  grep -F "mariadb-operator $cmd" "$work/sub" >/dev/null ||
    fail "$cmd --help has no usage line: $(cat "$work/sub")"
done
status=0
run "$image" --definitely-invalid >"$work/invalid" 2>&1 || status=$?
test "$status" -ne 0 || fail 'an invalid flag was accepted'
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"

# The binary also runs from its package path.
run --entrypoint /usr/bin/mariadb-operator "$image" --help >/dev/null 2>&1 ||
  fail '/usr/bin/mariadb-operator does not run'

# Without any cluster configuration the operator refuses to start.
status=0
run "$image" >"$work/nocluster" 2>&1 || status=$?
test "$status" -ne 0 || fail 'operator outside a cluster unexpectedly succeeded'
grep -F 'Unable to get config' "$work/nocluster" >/dev/null ||
  fail "missing cluster config diagnostic: $(cat "$work/nocluster")"

# The image ships the CRDs generated for this build; install exactly those.
crds='backups connections databases externalmariadbs grants mariadbs maxscales
physicalbackups pointintimerecoveries restores sqljobs users'
mkdir -p "$work/crds"
holder=$(docker create "$image") || fail 'could not create a container to copy the CRDs'
docker cp "$holder:/usr/share/mariadb-operator/crds/." "$work/crds/" >/dev/null 2>&1 ||
  { docker rm "$holder" >/dev/null; fail 'image does not ship /usr/share/mariadb-operator/crds'; }
docker rm "$holder" >/dev/null
for crd in $crds; do
  [ -s "$work/crds/k8s.mariadb.com_$crd.yaml" ] || fail "missing CRD k8s.mariadb.com_$crd.yaml"
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
kubectl_image=$(pull_child "$kubectl_index")

# Control plane: etcd and kube-apiserver with a static admin token. No
# controller manager, scheduler, or kubelet runs, so the operator's objects are
# created but no MariaDB pod ever starts.
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
# The chart points MARIADB_OPERATOR_SA_PATH at the projected token.
printf '%s' "$token" >"$work/sa/token"
printf '%s' "$ns" >"$work/sa/namespace"
chmod 0755 "$work/sa"
chmod 0644 "$work/sa/token" "$work/sa/namespace"

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

# The MariaDB CRD exceeds the client-side apply annotation limit.
kubectl create -f /crds >"$work/crd" 2>&1 || fail "could not create the CRDs: $(cat "$work/crd")"
established=''
for crd in $crds; do
  established="$established crd/$crd.k8s.mariadb.com"
done
# shellcheck disable=SC2086
kubectl wait --for=condition=Established --timeout=60s $established >"$work/established" 2>&1 ||
  fail "CRDs not established: $(cat "$work/established")"

kubectl create namespace "$ns" >/dev/null || fail 'could not create the namespace'

# The environment the chart's mariadb-operator-env ConfigMap and Deployment
# provide, with the upstream defaults of this release.
operator_env() {
  cat <<EOF
MARIADB_OPERATOR_NAME=mariadb-operator
MARIADB_OPERATOR_NAMESPACE=$ns
MARIADB_OPERATOR_SA_PATH=/var/run/secrets/kubernetes.io/serviceaccount/token
MARIADB_OPERATOR_IMAGE=$image
RELATED_IMAGE_MARIADB=$mariadb_image
RELATED_IMAGE_MARIADB_NAME=docker-registry1.mariadb.com/library/mariadb
RELATED_IMAGE_MAXSCALE=docker-registry2.mariadb.com/mariadb/maxscale:23.08.13-2
RELATED_IMAGE_EXPORTER=prom/mysqld-exporter:v0.15.1
RELATED_IMAGE_EXPORTER_MAXSCALE=docker-registry2.mariadb.com/mariadb/maxscale-prometheus-exporter-ubi:v0.0.1
MARIADB_GALERA_LIB_PATH=/usr/lib/galera/libgalera_smm.so
MARIADB_DEFAULT_VERSION=12.3
WATCH_NAMESPACE=$ns
EOF
}
operator_env >"$work/env"

# A cluster without the operator environment fails before it starts a manager.
status=0
docker run --rm --network "$network" --read-only --cap-drop=ALL \
  -v "$work/kube:/kube:ro" -e KUBECONFIG=/kube/config "$image" >"$work/noenv" 2>&1 || status=$?
test "$status" -ne 0 || fail 'operator without its environment unexpectedly succeeded'
grep -F 'Error getting environment' "$work/noenv" >/dev/null ||
  fail "missing environment diagnostic: $(cat "$work/noenv")"

# Out of cluster with a kubeconfig: read-only root, no capabilities, leader
# election, one watched namespace, and the webhook disabled as in the chart.
# The chart runs the webhook as its own Deployment; the operator registers its
# health checks only with --webhook, so the chart gives it no probes and the
# metrics endpoint shows that the manager is serving.
docker run -d --name "$op" --network "$network" --read-only --cap-drop=ALL \
  -p 127.0.0.1::8080 \
  -v "$work/kube:/kube:ro" -v "$work/sa:/var/run/secrets/kubernetes.io/serviceaccount:ro" \
  -e KUBECONFIG=/kube/config --env-file "$work/env" \
  "$image" --metrics-addr=:8080 --leader-elect >/dev/null

metrics=$(docker port "$op" 8080/tcp | head -n 1)
[ -n "$metrics" ] || fail 'metrics port is not published'
# Controllers start only after the leader election lease is held.
i=0
until curl -fsS "http://$metrics/metrics" >"$work/metrics" 2>/dev/null &&
  grep -E '^controller_runtime_active_workers\{controller="mariadb"\} ' "$work/metrics" >/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'operator metrics do not report a started mariadb controller'
  sleep 2
done

i=0
until kubectl get lease -n "$ns" mariadb-operator.mariadb.com \
  -o 'jsonpath={.spec.holderIdentity}' >"$work/holder" 2>/dev/null && [ -s "$work/holder" ]; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail 'operator did not acquire its leader election lease'
  sleep 2
done

docker logs "$op" >"$work/oplog" 2>&1
grep -F 'Watching namespaces' "$work/oplog" | grep -F "$ns" >/dev/null ||
  fail 'operator log does not report the watched namespace'
grep -F 'Discovery info' "$work/oplog" >/dev/null || fail 'operator did not run API discovery'

# The CRD schema shipped in the image rejects an invalid storage size.
status=0
kubectl apply -f - >"$work/badsize" 2>&1 <<EOF || status=$?
apiVersion: k8s.mariadb.com/v1alpha1
kind: MariaDB
metadata:
  name: badsize
  namespace: $ns
spec:
  storage:
    size: banana
EOF
test "$status" -ne 0 || fail 'an invalid storage size was accepted'
grep -F 'spec.storage.size' "$work/badsize" >/dev/null ||
  fail "storage size rejection is missing: $(cat "$work/badsize")"

kubectl apply -f - >"$work/mariadb" 2>&1 <<EOF || fail "could not create the MariaDB: $(cat "$work/mariadb")"
apiVersion: k8s.mariadb.com/v1alpha1
kind: MariaDB
metadata:
  name: smoke
  namespace: $ns
spec:
  rootPasswordSecretKeyRef:
    name: smoke-root
    key: password
    generate: true
  username: app
  passwordSecretKeyRef:
    name: smoke-app
    key: password
    generate: true
  database: app
  port: 3306
  storage:
    size: 1Gi
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

# The operator generates the requested root and user passwords.
for secret in smoke-root smoke-app; do
  wait_for "the generated $secret Secret" get secret -n "$ns" "$secret" -o 'jsonpath={.data.password}'
  test "$(base64 -d <"$work/out" | wc -c)" -ge 16 || fail "generated $secret password is too short"
done

wait_for 'the StatefulSet' get statefulset -n "$ns" smoke -o name
kubectl get statefulset -n "$ns" smoke -o json >"$work/sts.json"
jq -e --arg img "$mariadb_image" '
  .spec.replicas == 1
  and .spec.serviceName == "smoke-internal"
  and (.metadata.ownerReferences[0].kind == "MariaDB")
  and ([.spec.template.spec.containers[] | select(.name == "mariadb") | .image] == [$img])
  and ([.spec.template.spec.containers[] | select(.name == "mariadb") | .ports[].containerPort]
       | index(3306) != null)
  and (.spec.volumeClaimTemplates[0].spec.resources.requests.storage == "1Gi")
' "$work/sts.json" >/dev/null ||
  fail "unexpected StatefulSet: $(jq -c '{svc: .spec.serviceName, replicas: .spec.replicas, owner: .metadata.ownerReferences, containers: [.spec.template.spec.containers[] | {name, image}], storage: .spec.volumeClaimTemplates[0].spec.resources.requests}' "$work/sts.json")"

for svc in smoke smoke-internal; do
  wait_for "service $svc" get service -n "$ns" "$svc" -o 'jsonpath={.spec.ports[*].port}'
  grep -Fw 3306 "$work/out" >/dev/null || fail "service $svc does not expose 3306: $(cat "$work/out")"
done

# With no kubelet the database never becomes ready, and the operator says so.
wait_for 'the MariaDB Ready condition' get mariadb -n "$ns" smoke \
  -o 'jsonpath={.status.conditions[?(@.type=="Ready")].status}'
test "$(cat "$work/out")" = False || fail "unexpected Ready condition: $(cat "$work/out")"

curl -fsS "http://$metrics/metrics" >"$work/metrics" || fail 'metrics endpoint failed'
grep -E '^controller_runtime_reconcile_total\{controller="mariadb",result="[a-z_]+"\} [1-9]' \
  "$work/metrics" >/dev/null ||
  fail "no MariaDB reconciles in metrics: $(grep controller_runtime_reconcile_total "$work/metrics")"

# SIGTERM shuts the manager down cleanly.
docker stop --time 20 "$op" >/dev/null || fail 'could not stop the operator'
test "$(docker inspect --format '{{.State.ExitCode}}' "$op")" = 0 ||
  fail "operator exited $(docker inspect --format '{{.State.ExitCode}}' "$op") on SIGTERM"

echo "mariadb-operator $expected_version: OK"
