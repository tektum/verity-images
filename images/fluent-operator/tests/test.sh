#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# Peers for a real control plane: Verity etcd 3.7, kube-apiserver 1.37 and
# kubectl 1.35, pinned by digest. The operator creates every workload object
# itself, so no controller manager, scheduler or kubelet is needed.
etcd_index=ghcr.io/tektum/etcd@sha256:fc322841b20ac374159333e013fb417aa712e776380c53dc34ab8a1958c07fd2
api_index=ghcr.io/tektum/kube-apiserver@sha256:b46742424f608bb186b83390c41cbe7f97df411ae3cf8fc3e4578c096a6b57bd
kubectl_index=ghcr.io/tektum/kubectl@sha256:537780af388652be3a0130aacd6d1cfed24704ab6a820c6c7024602ec7777332

id=$$
network="verity-fluentop-$id"
etcd="verity-fluentop-etcd-$id"
api="verity-fluentop-api-$id"
op="verity-fluentop-op-$id"
work=$(mktemp -d)
ns=fluent

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
  '["/usr/bin/manager"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = / ||
  fail 'unexpected working directory'

# Upstream runs read-only as 65532 with every capability dropped.
run() {
  docker run --rm --network none --read-only --cap-drop=ALL "$@"
}

# CLI surface: Go flag parsing, as upstream.
run "$image" --help >"$work/help" 2>&1 || fail "help failed: $(cat "$work/help")"
for flag in -health-probe-bind-address -metrics-bind-address -metrics-secure \
  -leader-elect -watch-namespaces -disable-component-controllers -webhook-cert-path \
  -zap-log-level; do
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

# Past flag parsing, without any cluster configuration, the manager logs the
# missing kubeconfig and exits non-zero instead of hanging or crashing.
status=0
run "$image" >"$work/nocluster" 2>&1 || status=$?
test "$status" -eq 1 || fail "manager outside a cluster exited $status, want 1: $(cat "$work/nocluster")"
grep -F 'unable to get kubeconfig' "$work/nocluster" >/dev/null ||
  fail "kubeconfig diagnostic is missing: $(cat "$work/nocluster")"
if grep -F 'panic:' "$work/nocluster" >/dev/null; then
  fail "manager panicked outside a cluster: $(cat "$work/nocluster")"
fi

# The image ships the CRDs generated for this build; install exactly those.
mkdir -p "$work/crds"
holder=$(docker create "$image") || fail 'could not create a container to copy the CRDs'
docker cp "$holder:/usr/share/fluent-operator/crds/." "$work/crds/" >/dev/null 2>&1 ||
  { docker rm "$holder" >/dev/null; fail 'image does not ship /usr/share/fluent-operator/crds'; }
docker rm "$holder" >/dev/null
crd_count=$(find "$work/crds" -name '*.yaml' | wc -l)
test "$crd_count" -eq 22 || fail "image ships $crd_count CRDs, want 22"
for crd in fluentbit.fluent.io_fluentbits fluentbit.fluent.io_clusterfluentbitconfigs \
  fluentbit.fluent.io_clusterinputs fluentbit.fluent.io_clusteroutputs \
  fluentd.fluent.io_fluentds fluentd.fluent.io_fluentdconfigs fluentd.fluent.io_outputs; do
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
kubectl_image=$(pull_child "$kubectl_index")

# Control plane: etcd and kube-apiserver with a static admin token.
mkdir -p "$work/pki" "$work/kube" "$work/sa" "$work/env"
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
# Out of cluster, leader election still reads the operator namespace from the
# service account mount.
printf '%s' "$ns" >"$work/sa/namespace"
# Upstream's chart mounts this file at /fluent-operator; the operator derives
# the Fluent Bit container log host path from CONTAINER_ROOT_DIR.
printf 'CONTAINER_ROOT_DIR=/srv/verity-docker\n' >"$work/env/fluent-bit.env"
chmod 0755 "$work/sa" "$work/env"
chmod 0644 "$work/sa/namespace" "$work/env/fluent-bit.env"

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

# Several CRDs exceed the client-side apply annotation limit.
kubectl create -f /crds >"$work/crd" 2>&1 || fail "could not create the CRDs: $(cat "$work/crd")"
kubectl wait --for=condition=Established --timeout=60s \
  crd/fluentbits.fluentbit.fluent.io crd/clusterfluentbitconfigs.fluentbit.fluent.io \
  crd/clusterinputs.fluentbit.fluent.io crd/clusteroutputs.fluentbit.fluent.io \
  crd/fluentds.fluentd.fluent.io crd/fluentdconfigs.fluentd.fluent.io \
  crd/outputs.fluentd.fluent.io >"$work/established" 2>&1 ||
  fail "CRDs not established: $(cat "$work/established")"

kubectl apply -f - >"$work/apply" 2>&1 <<EOF || fail "could not create the namespace: $(cat "$work/apply")"
apiVersion: v1
kind: Namespace
metadata:
  name: $ns
EOF

# Out of cluster with a kubeconfig: read-only root, no capabilities, leader
# election, cluster scope as upstream's chart deploys it, and the chart's
# environment file. The chart sets NAMESPACE from the downward API; the
# rendered Fluent Bit configuration Secret is written there.
docker run -d --name "$op" --network "$network" --read-only --cap-drop=ALL \
  -p 127.0.0.1::8081 -p 127.0.0.1::8080 \
  -v "$work/kube:/kube:ro" -v "$work/sa:/var/run/secrets/kubernetes.io/serviceaccount:ro" \
  -v "$work/env:/fluent-operator:ro" -e KUBECONFIG=/kube/config -e NAMESPACE="$ns" \
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

i=0
until kubectl get lease -n "$ns" 45c4fdd2.fluent.io \
  -o 'jsonpath={.spec.holderIdentity}' >"$work/holder" 2>/dev/null && [ -s "$work/holder" ]; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail 'operator did not acquire its leader election lease'
  sleep 2
done

# The CRD schema shipped in the image rejects a non-integer dummy rate.
status=0
kubectl apply -f - >"$work/badrate" 2>&1 <<EOF || status=$?
apiVersion: fluentbit.fluent.io/v1alpha2
kind: ClusterInput
metadata:
  name: bad-rate
spec:
  dummy:
    tag: bad
    rate: fast
EOF
test "$status" -ne 0 || fail 'a non-integer dummy rate was accepted'
grep -F 'spec.dummy.rate' "$work/badrate" >/dev/null ||
  fail "dummy rate rejection is missing: $(cat "$work/badrate")"

# Upstream's quick-start Fluent Bit and Fluentd pipelines. No kubelet runs, so
# the referenced images are never pulled.
kubectl apply -f - >"$work/fixtures" 2>&1 <<EOF || fail "could not create the pipelines: $(cat "$work/fixtures")"
apiVersion: fluentbit.fluent.io/v1alpha2
kind: FluentBit
metadata:
  name: fluent-bit
  namespace: $ns
  labels:
    app.kubernetes.io/name: fluent-bit
spec:
  image: ghcr.io/fluent/fluent-operator/fluent-bit:5.1.5
  fluentBitConfigName: fluent-bit-config
---
apiVersion: fluentbit.fluent.io/v1alpha2
kind: ClusterFluentBitConfig
metadata:
  name: fluent-bit-config
  labels:
    app.kubernetes.io/name: fluent-bit
spec:
  inputSelector:
    matchLabels:
      fluentbit.fluent.io/enabled: "true"
  outputSelector:
    matchLabels:
      fluentbit.fluent.io/enabled: "true"
---
apiVersion: fluentbit.fluent.io/v1alpha2
kind: ClusterInput
metadata:
  name: dummy
  labels:
    fluentbit.fluent.io/enabled: "true"
spec:
  dummy:
    tag: my_dummy
---
apiVersion: fluentbit.fluent.io/v1alpha2
kind: ClusterOutput
metadata:
  name: stdout
  labels:
    fluentbit.fluent.io/enabled: "true"
spec:
  match: "*"
  stdout: {}
---
apiVersion: fluentd.fluent.io/v1alpha1
kind: Fluentd
metadata:
  name: fluentd-forward
  namespace: $ns
  labels:
    app.kubernetes.io/name: fluentd
spec:
  globalInputs:
    - forward:
        bind: 0.0.0.0
        port: 24224
  replicas: 1
  image: ghcr.io/fluent/fluent-operator/fluentd:v1.19.4
  fluentdCfgSelector:
    matchLabels:
      config.fluentd.fluent.io/enabled: "true"
---
apiVersion: fluentd.fluent.io/v1alpha1
kind: FluentdConfig
metadata:
  name: fluentd-config
  namespace: $ns
  labels:
    config.fluentd.fluent.io/enabled: "true"
spec:
  outputSelector:
    matchLabels:
      output.fluentd.fluent.io/enabled: "true"
---
apiVersion: fluentd.fluent.io/v1alpha1
kind: Output
metadata:
  name: fluentd-stdout
  namespace: $ns
  labels:
    output.fluentd.fluent.io/enabled: "true"
spec:
  outputs:
    - stdout: {}
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

# secret_key NAME KEY: print one decoded key of a Secret in the namespace.
secret_key() {
  kubectl get secret -n "$ns" "$1" -o json | jq -er --arg k "$2" '.data[$k] | @base64d'
}

# wait_rendered NAME KEY PATTERN...: poll until one decoded Secret key matches
# every extended regular expression. Plugins applied together can be rendered
# in more than one reconcile, so a single snapshot may be incomplete.
wait_rendered() {
  name=$1
  key=$2
  shift 2
  i=0
  while :; do
    missing=
    if secret_key "$name" "$key" >"$work/rendered" 2>/dev/null; then
      for pattern in "$@"; do
        grep -Eq -e "$pattern" "$work/rendered" || { missing=$pattern; break; }
      done
    else
      missing="a $key key in Secret $name"
    fi
    [ -n "$missing" ] || return 0
    i=$((i + 1))
    [ "$i" -lt 60 ] || fail "$name $key does not match $missing: $(cat "$work/rendered")"
    sleep 2
  done
}

# The rendered Fluent Bit configuration carries the selected input and output.
wait_rendered fluent-bit-config fluent-bit.conf '^\[Input\]$' '^ +Name +dummy$' \
  '^ +Tag +my_dummy$' '^\[Output\]$' '^ +Name +stdout$' '^ +Match +\*$'
test "$(kubectl get secret -n "$ns" fluent-bit-config \
  -o 'jsonpath={.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}')" = \
  ClusterFluentBitConfig/fluent-bit-config ||
  fail 'fluent-bit-config is not owned by the ClusterFluentBitConfig'

# The DaemonSet, its RBAC, and the log host path from the environment file.
wait_for 'the Fluent Bit DaemonSet' get daemonset -n "$ns" fluent-bit -o json
cp "$work/out" "$work/ds.json"
jq -e '.metadata.ownerReferences[0] | .kind == "FluentBit" and .name == "fluent-bit" and .controller' \
  "$work/ds.json" >/dev/null || fail 'the DaemonSet is not controlled by the FluentBit'
jq -e '.spec.template.spec.containers[0].image == "ghcr.io/fluent/fluent-operator/fluent-bit:5.1.5"' \
  "$work/ds.json" >/dev/null || fail "unexpected DaemonSet image: $(jq -c '.spec.template.spec.containers' "$work/ds.json")"
jq -e '.spec.template.spec.serviceAccountName == "fluent-bit"' "$work/ds.json" >/dev/null ||
  fail 'unexpected DaemonSet service account'
jq -e '.spec.template.spec.volumes[] | select(.name == "config") | .secret.secretName == "fluent-bit-config"' \
  "$work/ds.json" >/dev/null || fail 'the DaemonSet does not mount fluent-bit-config'
jq -e '.spec.template.spec.volumes[] | select(.name == "varlibcontainers")
  | .hostPath.path == "/srv/verity-docker/containers"' "$work/ds.json" >/dev/null ||
  fail "the DaemonSet ignores CONTAINER_ROOT_DIR: $(jq -c '.spec.template.spec.volumes' "$work/ds.json")"
wait_for 'the Fluent Bit service account' get serviceaccount -n "$ns" fluent-bit -o name
wait_for 'the Fluent Bit cluster role' get clusterrole fluent-operator-fluent-bit -o name
wait_for 'the Fluent Bit cluster role binding' \
  get clusterrolebinding fluent-operator-fluent-bit-fluent-bit -o 'jsonpath={.subjects[0].name}'
test "$(cat "$work/out")" = fluent-bit || fail "unexpected binding subject: $(cat "$work/out")"

# A changed input is re-rendered into the same secret.
kubectl patch clusterinput dummy --type merge -p '{"spec":{"dummy":{"tag":"verity_changed"}}}' \
  >"$work/patch" 2>&1 || fail "could not patch the input: $(cat "$work/patch")"
wait_rendered fluent-bit-config fluent-bit.conf '^ +Tag +verity_changed$'
if grep -Eq '^ +Tag +my_dummy$' "$work/rendered"; then
  fail "the old input tag is still rendered: $(cat "$work/rendered")"
fi

# Fluentd: the StatefulSet and its rendered configuration. fluent.conf only
# includes the generated files; app.conf carries the inputs and outputs.
wait_rendered fluentd-forward-config fluent.conf '^@include /fluentd/etc/app\.conf$'
wait_rendered fluentd-forward-config app.conf '@type +forward' 'port +24224' '@type +stdout'
wait_for 'the Fluentd StatefulSet' get statefulset -n "$ns" fluentd-forward -o json
jq -e '.metadata.ownerReferences[0].kind == "Fluentd"
  and .spec.template.spec.containers[0].image == "ghcr.io/fluent/fluent-operator/fluentd:v1.19.4"' \
  "$work/out" >/dev/null || fail "unexpected Fluentd StatefulSet: $(jq -c '{o: .metadata.ownerReferences, c: .spec.template.spec.containers}' "$work/out")"

curl -fsS "http://$metrics/metrics" >"$work/metrics" || fail 'metrics endpoint failed'
for controller in FluentBit FluentBitConfig Fluentd FluentdConfig; do
  grep -E "^controller_runtime_reconcile_total\{controller=\"$controller\",result=\"success\"\} [1-9]" \
    "$work/metrics" >/dev/null ||
    fail "no successful $controller reconciles in metrics: $(grep controller_runtime_reconcile_total "$work/metrics")"
done
docker logs "$op" >"$work/oplog" 2>&1
if grep -F 'panic:' "$work/oplog" >/dev/null; then
  fail "operator panicked: $(grep -F -A5 'panic:' "$work/oplog")"
fi

# SIGTERM shuts the manager down cleanly.
docker stop --time 20 "$op" >/dev/null || fail 'could not stop the operator'
test "$(docker inspect --format '{{.State.ExitCode}}' "$op")" = 0 ||
  fail "operator exited $(docker inspect --format '{{.State.ExitCode}}' "$op") on SIGTERM"

echo "fluent-operator $expected_version: OK"
