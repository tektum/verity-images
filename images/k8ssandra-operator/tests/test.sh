#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# Peers for a real control plane: Verity etcd 3.7, kube-apiserver 1.37 and
# kubectl 1.35, plus the catalog's cass-operator 1.33 that this operator drives,
# pinned by digest.
etcd_index=ghcr.io/tektum/etcd@sha256:fc322841b20ac374159333e013fb417aa712e776380c53dc34ab8a1958c07fd2
api_index=ghcr.io/tektum/kube-apiserver@sha256:b46742424f608bb186b83390c41cbe7f97df411ae3cf8fc3e4578c096a6b57bd
kubectl_index=ghcr.io/tektum/kubectl@sha256:537780af388652be3a0130aacd6d1cfed24704ab6a820c6c7024602ec7777332
cassop_index=ghcr.io/tektum/cass-operator@sha256:0cf996f71b1bbf4189d80d463f2c054dfbbc1a80dbc1983eee3391795df1080d

id=$$
network="verity-k8ssop-$id"
etcd="verity-k8ssop-etcd-$id"
api="verity-k8ssop-api-$id"
cassop="verity-k8ssop-cassop-$id"
op="verity-k8ssop-op-$id"
noconfig="verity-k8ssop-noconfig-$id"
work=$(mktemp -d)
ns=k8ssandra-operator

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  for c in "$op" "$cassop" "$api"; do
    printf -- '--- %s\n' "$c" >&2
    docker logs "$c" 2>&1 | tail -n 40 >&2 || true
  done
  exit 1
}

cleanup() {
  docker rm -f "$op" "$noconfig" "$cassop" "$api" "$etcd" >/dev/null 2>&1 || true
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

# Upstream runs as 65532 with privilege escalation disabled; run read-only with
# every capability dropped.
run() {
  docker run --rm --network none --read-only --cap-drop=ALL "$@"
}

# CLI surface: Go flag parsing, as upstream.
run "$image" --help >"$work/help" 2>&1 || fail "help failed: $(cat "$work/help")"
for flag in -health-probe-bind-address -metrics-bind-address -leader-elect \
  -zap-log-level -zap-devel; do
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
cassop_image=$(pull_child "$cassop_index")

# copy_crds IMAGE DIR: copy the CRDs an image ships under DIR.
copy_crds() {
  holder=$(docker create "$1") || fail "could not create a container from $1"
  docker cp "$holder:$2/." "$work/crds/" >/dev/null 2>&1 ||
    { docker rm "$holder" >/dev/null; fail "$1 does not ship $2"; }
  docker rm "$holder" >/dev/null
}

# The image ships the CRDs generated for this build; install exactly those,
# next to the CassandraDatacenter and CassandraTask CRDs of the catalog's
# cass-operator, which this operator creates and watches.
mkdir -p "$work/crds"
copy_crds "$image" /usr/share/k8ssandra-operator/crds
for crd in k8ssandra.io_k8ssandraclusters control.k8ssandra.io_k8ssandratasks \
  config.k8ssandra.io_clientconfigs replication.k8ssandra.io_replicatedsecrets \
  reaper.k8ssandra.io_reapers medusa.k8ssandra.io_medusabackupjobs \
  medusa.k8ssandra.io_medusabackupschedules medusa.k8ssandra.io_medusaconfigurations \
  medusa.k8ssandra.io_medusarestorejobs medusa.k8ssandra.io_medusatasks; do
  [ -s "$work/crds/$crd.yaml" ] || fail "missing CRD $crd.yaml"
done
copy_crds "$cassop_image" /usr/share/cass-operator/crds
for crd in cassandra.datastax.com_cassandradatacenters control.k8ssandra.io_cassandratasks; do
  [ -s "$work/crds/$crd.yaml" ] || fail "cass-operator image is missing CRD $crd.yaml"
done
chmod -R a+rX "$work/crds"

# Control plane: etcd and kube-apiserver with a static admin token. No
# scheduler or kubelet runs, so Cassandra pods are never started.
mkdir -p "$work/pki" "$work/kube" "$work/sa" "$work/certs"
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
# Out of cluster both operators still read their own namespace from the service
# account mount; the shared image config ConfigMap is looked up there.
printf '%s' "$ns" >"$work/sa/namespace"
chmod 0755 "$work/sa"
chmod 0644 "$work/sa/namespace"
# The manager always registers its admission webhooks, so the webhook server
# needs a serving certificate where upstream's deployment mounts cert-manager's.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=k8ssandra-operator-webhook' \
  -addext 'subjectAltName=IP:127.0.0.1' \
  -keyout "$work/certs/tls.key" -out "$work/certs/tls.crt" >/dev/null 2>&1 ||
  fail 'could not generate the webhook serving certificate'
chmod 0755 "$work/certs"
chmod 0644 "$work/certs/tls.key" "$work/certs/tls.crt"

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

# The K8ssandraCluster CRD exceeds the client-side apply annotation limit.
kubectl create -f /crds >"$work/crd" 2>&1 || fail "could not create the CRDs: $(cat "$work/crd")"
set --
for crd in "$work"/crds/*.yaml; do
  name=$(basename "$crd" .yaml)
  set -- "$@" "crd/${name#*_}.${name%%_*}"
done
kubectl wait --for=condition=Established --timeout=60s "$@" >"$work/established" 2>&1 ||
  fail "CRDs not established: $(cat "$work/established")"

# The cass-operator image ships its generated config/crd/bases. Upstream's
# config/crd kustomization, which k8ssandra-operator's deployments install,
# then applies patches/config_removal.yaml and patches/remove_xkeys.yaml:
# spec.config is free-form JSON, and the generated `format: byte` schema would
# reject every datacenter this operator writes. Apply the same JSON patches.
spec=/spec/versions/0/schema/openAPIV3Schema/properties/spec/properties
pod=$spec/podTemplateSpec/properties/spec/properties
kubectl patch crd cassandradatacenters.cassandra.datastax.com --type=json -p "[
  {\"op\":\"remove\",\"path\":\"$spec/config\"},
  {\"op\":\"remove\",\"path\":\"$pod/containers/items/properties/ports/x-kubernetes-list-map-keys\"},
  {\"op\":\"remove\",\"path\":\"$pod/containers/items/properties/ports/x-kubernetes-list-type\"},
  {\"op\":\"remove\",\"path\":\"$pod/initContainers/items/properties/ports/x-kubernetes-list-map-keys\"},
  {\"op\":\"remove\",\"path\":\"$pod/initContainers/items/properties/ports/x-kubernetes-list-type\"},
  {\"op\":\"remove\",\"path\":\"$pod/topologySpreadConstraints/x-kubernetes-list-map-keys\"},
  {\"op\":\"remove\",\"path\":\"$pod/topologySpreadConstraints/x-kubernetes-list-type\"}
]" >"$work/crdpatch" 2>&1 || fail "could not apply upstream's CRD patches: $(cat "$work/crdpatch")"

kubectl apply -f - >"$work/apply" 2>&1 <<EOF || fail "could not create the namespace: $(cat "$work/apply")"
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
EOF

# operator NAME ARGS...: run this image as upstream's deployment does: out of
# cluster with a kubeconfig, read-only root, no capabilities, one watched
# namespace, and the control-plane role.
operator() {
  name=$1
  shift
  docker run -d --name "$name" --network "$network" --read-only --cap-drop=ALL \
    -v "$work/kube:/kube:ro" -v "$work/sa:/var/run/secrets/kubernetes.io/serviceaccount:ro" \
    -v "$work/certs:/tmp/k8s-webhook-server/serving-certs:ro" \
    -e KUBECONFIG=/kube/config -e WATCH_NAMESPACE="$ns" -e K8SSANDRA_CONTROL_PLANE=true \
    -e OPERATOR_NAMESPACE="$ns" "$@" >/dev/null
}

# Upstream requires the image config; without it the manager exits.
operator "$noconfig" "$image"
i=0
while running=$(docker inspect --format '{{.State.Running}}' "$noconfig") &&
  [ "$running" = true ]; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail 'the manager kept running without an image config'
  sleep 1
done
test "$(docker inspect --format '{{.State.ExitCode}}' "$noconfig")" -ne 0 ||
  fail 'the manager exited 0 without an image config'
docker logs "$noconfig" >"$work/noconfig" 2>&1
grep -F 'unable to load image config from ConfigMap (v1beta2)' "$work/noconfig" >/dev/null ||
  fail "missing image config diagnostic: $(tail -n 5 "$work/noconfig")"

# The image config is the one upstream's config/cass-operator/imageconfig
# component deploys as this labeled ConfigMap, shared with cass-operator.
kubectl apply -f - >"$work/apply" 2>&1 <<EOF || fail "could not create fixtures: $(cat "$work/apply")"
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
        tag: v1.33.1
      config-builder:
        repository: datastax
        name: cass-config-builder
        tag: 1.0-ubi
      k8ssandra-client:
        repository: k8ssandra
        name: k8ssandra-client
        tag: v0.9.2
      medusa:
        registry: docker.io
        repository: k8ssandra
        name: medusa
        tag: 0.31.1
      reaper:
        registry: docker.io
        repository: thelastpickle
        name: cassandra-reaper
        tag: 5.1.0
    defaults:
      registry: ghcr.io
      pullPolicy: IfNotPresent
    types:
      cassandra:
        repository: k8ssandra
        name: cass-management-api
        suffix: -ubi
EOF

operator "$op" -p 127.0.0.1::8081 -p 127.0.0.1::8080 -p 127.0.0.1::9443 "$image" \
  --leader-elect --health-probe-bind-address=:8081 --metrics-bind-address=:8080
# cass-operator from the catalog, deployed beside it in the same namespace as
# upstream's config/deployments does.
docker run -d --name "$cassop" --network "$network" --read-only --cap-drop=ALL \
  -v "$work/kube:/kube:ro" -v "$work/sa:/var/run/secrets/kubernetes.io/serviceaccount:ro" \
  -e KUBECONFIG=/kube/config -e WATCH_NAMESPACE="$ns" "$cassop_image" \
  --health-probe-bind-address=:8081 --metrics-bind-address=:8080 >/dev/null

probe=$(docker port "$op" 8081/tcp | head -n 1)
metrics=$(docker port "$op" 8080/tcp | head -n 1)
webhook=$(docker port "$op" 9443/tcp | head -n 1)
[ -n "$probe" ] && [ -n "$metrics" ] && [ -n "$webhook" ] ||
  fail 'probe, metrics or webhook port is not published'
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
for line in 'watch namespace configured' 'Adding watch namespace to DefaultNamespaces' \
  'Serving webhook server' 'starting manager'; do
  grep -F "$line" "$work/oplog" >/dev/null || fail "operator log is missing: $line"
done

# The validating webhook serves the mounted certificate. Send it admission
# reviews directly, as the API server would once a webhook configuration with
# that CA is registered.
# review SPEC: print the AdmissionResponse for creating a cluster with SPEC.
review() {
  printf '%s' "{\"apiVersion\":\"admission.k8s.io/v1\",\"kind\":\"AdmissionReview\",
    \"request\":{\"uid\":\"verity-$id\",
    \"kind\":{\"group\":\"k8ssandra.io\",\"version\":\"v1alpha1\",\"kind\":\"K8ssandraCluster\"},
    \"resource\":{\"group\":\"k8ssandra.io\",\"version\":\"v1alpha1\",\"resource\":\"k8ssandraclusters\"},
    \"name\":\"probe\",\"namespace\":\"$ns\",\"operation\":\"CREATE\",
    \"userInfo\":{\"username\":\"verity-admin\"},
    \"object\":{\"apiVersion\":\"k8ssandra.io/v1alpha1\",\"kind\":\"K8ssandraCluster\",
    \"metadata\":{\"name\":\"probe\",\"namespace\":\"$ns\"},\"spec\":$1}}}" |
    curl -fsS --cacert "$work/certs/tls.crt" -H 'Content-Type: application/json' --data-binary @- \
      "https://$webhook/validate-k8ssandra-io-v1alpha1-k8ssandracluster"
}
review '{"cassandra":{"serverVersion":"4.1.8","datacenters":[{"metadata":{"name":"dc1"},"size":1}]}}' \
  >"$work/denied" || fail 'the validating webhook did not answer'
jq -e --arg uid "verity-$id" '.response.uid == $uid and .response.allowed == false
  and (.response.status.message | contains("storageConfig must be defined at cluster level or dc level"))' \
  "$work/denied" >/dev/null || fail "webhook did not deny a cluster without storage: $(cat "$work/denied")"
review '{"cassandra":{"serverVersion":"4.1.8","datacenters":[{"metadata":{"name":"dc1"},"size":1,
  "storageConfig":{"cassandraDataVolumeClaimSpec":{"accessModes":["ReadWriteOnce"],
  "resources":{"requests":{"storage":"1Gi"}}}}}]}}' >"$work/allowed" ||
  fail 'the validating webhook did not answer'
jq -e '.response.allowed == true' "$work/allowed" >/dev/null ||
  fail "webhook denied a valid cluster: $(cat "$work/allowed")"

i=0
until kubectl get lease -n "$ns" dcabfccc.k8ssandra.io \
  -o 'jsonpath={.spec.holderIdentity}' >"$work/holder" 2>/dev/null && [ -s "$work/holder" ]; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail 'operator did not acquire its leader election lease'
  sleep 2
done

# The CRD schema shipped in the image rejects a malformed server version.
status=0
kubectl apply -f - >"$work/badversion" 2>&1 <<EOF || status=$?
apiVersion: k8ssandra.io/v1alpha1
kind: K8ssandraCluster
metadata:
  name: badversion
  namespace: $ns
spec:
  cassandra:
    serverVersion: banana
    datacenters:
      - metadata:
          name: dc1
        size: 1
EOF
test "$status" -ne 0 || fail 'a malformed serverVersion was accepted'
grep -F 'spec.cassandra.serverVersion' "$work/badversion" >/dev/null ||
  fail "serverVersion rejection is missing: $(cat "$work/badversion")"

kubectl apply -f - >"$work/kc" 2>&1 <<EOF || fail "could not create the clusters: $(cat "$work/kc")"
apiVersion: k8ssandra.io/v1alpha1
kind: K8ssandraCluster
metadata:
  name: verity
  namespace: $ns
spec:
  cassandra:
    serverVersion: 4.1.8
    datacenters:
      - metadata:
          name: dc1
        size: 1
        storageConfig:
          cassandraDataVolumeClaimSpec:
            accessModes: [ReadWriteOnce]
            resources:
              requests:
                storage: 1Gi
---
apiVersion: k8ssandra.io/v1alpha1
kind: K8ssandraCluster
metadata:
  name: remote
  namespace: $ns
spec:
  cassandra:
    serverVersion: 4.1.8
    datacenters:
      - metadata:
          name: dc9
        k8sContext: missing
        size: 1
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

# The operator generates the superuser secret, replicates it, and creates the
# CassandraDatacenter, with its free-form server config, that the catalog's
# cass-operator CRD accepts.
wait_for 'the superuser secret' get secret -n "$ns" verity-superuser -o 'jsonpath={.data.password}'
kubectl get secret -n "$ns" verity-superuser -o 'jsonpath={.data.username}' >"$work/user"
test "$(base64 -d <"$work/user")" = verity-superuser || fail 'unexpected superuser name'
wait_for 'the ReplicatedSecret' get replicatedsecret -n "$ns" verity -o name

wait_for 'the CassandraDatacenter' get cassandradatacenter -n "$ns" dc1 -o name
kubectl get cassandradatacenter -n "$ns" dc1 -o json >"$work/dc.json"
jq -e --arg ns "$ns" '
  .spec.clusterName == "verity"
  and .spec.serverType == "cassandra"
  and .spec.serverVersion == "4.1.8"
  and .spec.size == 1
  and .spec.superuserSecretName == "verity-superuser"
  and .spec.config["cassandra-yaml"].authenticator == "PasswordAuthenticator"
  and .metadata.labels["app.kubernetes.io/name"] == "k8ssandra-operator"
  and .metadata.labels["app.kubernetes.io/part-of"] == "k8ssandra"
  and .metadata.labels["k8ssandra.io/cluster-name"] == "verity"
  and .metadata.labels["k8ssandra.io/cluster-namespace"] == $ns
  and ([.metadata.ownerReferences[] | select(.kind == "K8ssandraCluster") | .name] == ["verity"])
  and (.spec.storageConfig.cassandraDataVolumeClaimSpec.resources.requests.storage == "1Gi")
' "$work/dc.json" >/dev/null || fail "unexpected CassandraDatacenter: $(jq -c '{spec: (.spec | {clusterName, serverType, serverVersion, size, superuserSecretName, config}), labels: .metadata.labels, owners: .metadata.ownerReferences}' "$work/dc.json")"

# cass-operator reconciles the generated datacenter into its StatefulSet.
sts=verity-dc1-default-sts
wait_for 'the StatefulSet' get statefulset -n "$ns" "$sts" -o name
kubectl get statefulset -n "$ns" "$sts" -o json >"$work/sts.json"
jq -e '
  .spec.replicas == 1
  and .metadata.labels["app.kubernetes.io/managed-by"] == "cass-operator"
  and (.metadata.ownerReferences[0].kind == "CassandraDatacenter")
  and ([.spec.template.spec.containers[] | select(.name == "cassandra") | .image]
       == ["ghcr.io/k8ssandra/cass-management-api:4.1.8-ubi"])
' "$work/sts.json" >/dev/null || fail "unexpected StatefulSet: $(jq -c '{replicas: .spec.replicas, labels: .metadata.labels, images: [.spec.template.spec.containers[].image]}' "$work/sts.json")"

# The cluster status reports the datacenter as cass-operator updates it.
wait_for 'the datacenter status' get k8ssandracluster -n "$ns" verity \
  -o 'jsonpath={.status.datacenters.dc1.cassandra.cassandraOperatorProgress}'
test "$(cat "$work/out")" = Updating || fail "unexpected datacenter progress: $(cat "$work/out")"

# A datacenter in an unknown Kubernetes context fails reconciliation with a
# Warning event and a status error, and nothing is created for it.
wait_for 'the remote cluster error' get k8ssandracluster -n "$ns" remote -o 'jsonpath={.status.error}'
grep -F 'No known client for context-name missing' "$work/out" >/dev/null ||
  fail "unexpected status error: $(cat "$work/out")"
i=0
until kubectl get events -n "$ns" -o json >"$work/events.json" 2>/dev/null &&
  jq -e '[.items[] | select(.involvedObject.name == "remote" and .type == "Warning"
    and .reason == "ReconcileError" and (.message | contains("No known client for context-name missing")))]
    | length > 0' "$work/events.json" >/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail "no ReconcileError event for the remote cluster: $(jq -c '[.items[] | select(.involvedObject.name == "remote") | .reason + "|" + .message]' "$work/events.json")"
  sleep 2
done
if kubectl get cassandradatacenter -n "$ns" dc9 -o name >/dev/null 2>&1; then
  fail 'a datacenter was created for an unknown context'
fi

curl -fsS "http://$metrics/metrics" >"$work/metrics" || fail 'metrics endpoint failed'
grep -E '^controller_runtime_reconcile_total\{controller="k8ssandracluster[^"]*",result="success"\} [1-9]' \
  "$work/metrics" >/dev/null || fail "no successful cluster reconciles in metrics: $(grep controller_runtime_reconcile_total "$work/metrics")"
grep -E '^controller_runtime_reconcile_total\{controller="k8ssandracluster[^"]*",result="error"\} [1-9]' \
  "$work/metrics" >/dev/null || fail "no failed cluster reconciles in metrics: $(grep controller_runtime_reconcile_total "$work/metrics")"

# SIGTERM shuts the manager down cleanly.
docker stop --time 20 "$op" >/dev/null || fail 'could not stop the operator'
test "$(docker inspect --format '{{.State.ExitCode}}' "$op")" = 0 ||
  fail "operator exited $(docker inspect --format '{{.State.ExitCode}}' "$op") on SIGTERM"

echo "k8ssandra-operator $expected_version: OK"
