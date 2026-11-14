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
network="verity-kwok-$id"
etcd="verity-kwok-etcd-$id"
api="verity-kwok-api-$id"
kwok="verity-kwok-ctl-$id"
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  for c in "$kwok" "$api"; do
    printf -- '--- %s\n' "$c" >&2
    docker logs "$c" 2>&1 | tail -n 30 >&2 || true
  done
  exit 1
}

cleanup() {
  docker rm -f "$kwok" "$api" "$etcd" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' "$here/../melange.yaml")
[ -n "$version" ] || fail 'could not read the recipe version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/kwok"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'

run() {
  docker run --rm --network none --read-only --tmpfs /tmp --cap-drop=ALL "$@"
}

# stdout only: docker prints a platform mismatch warning on stderr for emulated arm64 runs.
out=$(run "$image" --version) || fail 'version failed'
printf '%s\n' "$out" | grep -Ex "kwok version v$version go[0-9.]+ \\(linux/[a-z0-9]+\\)" >/dev/null ||
  fail "version does not report v$version: $out"

# Negative: an unknown flag is rejected.
status=0
run "$image" --definitely-invalid >"$work/invalid" 2>&1 || status=$?
test "$status" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"

# Negative: without any Stage configuration the controller refuses to start.
status=0
run "$image" --manage-all-nodes=true >"$work/nostages" 2>&1 || status=$?
test "$status" -ne 0 || fail 'controller without stages unexpectedly succeeded'
grep -F 'no stages found' "$work/nostages" >/dev/null ||
  fail "missing-stages diagnostic is missing: $(cat "$work/nostages")"

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
mkdir -p "$work/pki" "$work/kube" "$work/config"
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

# Stages adapted from upstream kustomize/stage/{node,pod}/fast: nodes become
# Ready and report the kwok version; pods become Ready and are deleted on request.
cat >"$work/config/kwok.yaml" <<'EOF'
apiVersion: kwok.x-k8s.io/v1alpha1
kind: Stage
metadata:
  name: node-initialize
spec:
  resourceRef:
    apiGroup: v1
    kind: Node
  selector:
    matchExpressions:
    - key: '.status.conditions.[] | select( .type == "Ready" ) | .status'
      operator: 'NotIn'
      values:
      - 'True'
  next:
    statusTemplate: |
      {{ $now := Now }}
      conditions:
      {{ range NodeConditions }}
      - lastHeartbeatTime: {{ $now | Quote }}
        lastTransitionTime: {{ $now | Quote }}
        message: {{ .message | Quote }}
        reason: {{ .reason | Quote }}
        status: {{ .status | Quote }}
        type: {{ .type | Quote }}
      {{ end }}
      addresses:
      - address: {{ NodeIP | Quote }}
        type: InternalIP
      - address: {{ NodeName | Quote }}
        type: Hostname
      allocatable:
        cpu: 1k
        memory: 1Ti
        pods: 1M
      capacity:
        cpu: 1k
        memory: 1Ti
        pods: 1M
      nodeInfo:
        architecture: amd64
        kubeletVersion: {{ printf "kwok-%s" Version | Quote }}
        operatingSystem: linux
      phase: Running
---
apiVersion: kwok.x-k8s.io/v1alpha1
kind: Stage
metadata:
  name: pod-ready
spec:
  resourceRef:
    apiGroup: v1
    kind: Pod
  selector:
    matchExpressions:
    - key: '.metadata.deletionTimestamp'
      operator: 'DoesNotExist'
    - key: '.status.phase'
      operator: 'In'
      values:
      - 'Pending'
  next:
    statusTemplate: |
      {{ $now := Now }}
      conditions:
      - lastTransitionTime: {{ $now | Quote }}
        status: "True"
        type: Initialized
      - lastTransitionTime: {{ $now | Quote }}
        status: "True"
        type: Ready
      - lastTransitionTime: {{ $now | Quote }}
        status: "True"
        type: ContainersReady
      containerStatuses:
      {{ range .spec.containers }}
      - image: {{ .image | Quote }}
        name: {{ .name | Quote }}
        ready: true
        restartCount: 0
        state:
          running:
            startedAt: {{ $now | Quote }}
      {{ end }}
      {{ with NodeIPsWith .spec.nodeName }}
      hostIP: {{ index . 0 | Quote }}
      {{ end }}
      {{ with PodIPsWith .spec.nodeName false ( or .metadata.uid "" ) ( or .metadata.name "" ) ( or .metadata.namespace "" ) }}
      podIP: {{ index . 0 | Quote }}
      {{ end }}
      phase: Running
      startTime: {{ $now | Quote }}
---
apiVersion: kwok.x-k8s.io/v1alpha1
kind: Stage
metadata:
  name: pod-delete
spec:
  resourceRef:
    apiGroup: v1
    kind: Pod
  selector:
    matchExpressions:
    - key: '.metadata.deletionTimestamp'
      operator: 'Exists'
  next:
    delete: true
EOF
chmod 0644 "$work/config/kwok.yaml"

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
  docker run --rm -i --network "$network" -v "$work/kube:/kube:ro" -e KUBECONFIG=/kube/config \
    "$kubectl_image" "$@"
}

i=0
until kubectl get --raw /readyz >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'kube-apiserver did not become ready'
  sleep 2
done

# The controller manages only nodes annotated kwok.x-k8s.io/node=fake.
docker run -d --name "$kwok" --network "$network" --read-only --tmpfs /tmp --cap-drop=ALL \
  -p 127.0.0.1::10247 -v "$work/kube:/kube:ro" -v "$work/config:/config:ro" "$image" \
  --config=/config/kwok.yaml --kubeconfig=/kube/config \
  --manage-nodes-with-annotation-selector=kwok.x-k8s.io/node=fake \
  --node-ip=10.240.0.10 --cidr=10.244.0.0/24 \
  --server-address=0.0.0.0:10247 >/dev/null

port=$(docker port "$kwok" 10247/tcp | awk -F: 'NR == 1 { print $NF }')
[ -n "$port" ] || fail 'kwok server port is not published'
i=0
until [ "$(curl -fsS "http://127.0.0.1:$port/healthz" 2>/dev/null)" = ok ]; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'kwok /healthz did not report ok'
  sleep 1
done

kubectl apply -f - >"$work/apply" 2>&1 <<'EOF' || fail "could not create fixtures: $(cat "$work/apply")"
apiVersion: v1
kind: Node
metadata:
  name: kwok-node-0
  annotations:
    kwok.x-k8s.io/node: fake
  labels:
    kubernetes.io/hostname: kwok-node-0
---
apiVersion: v1
kind: Node
metadata:
  name: unmanaged-node
  labels:
    kubernetes.io/hostname: unmanaged-node
---
# No controller-manager runs, so create the ServiceAccount that pod admission needs.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
  namespace: default
EOF

kubectl wait --for=condition=Ready node/kwok-node-0 --timeout=90s >"$work/wait-node" 2>&1 ||
  fail "fake node did not become Ready: $(cat "$work/wait-node")"
out=$(kubectl get node kwok-node-0 -o 'jsonpath={.status.nodeInfo.kubeletVersion}')
test "$out" = "kwok-v$version" || fail "node does not report kwok-v$version: $out"
out=$(kubectl get node kwok-node-0 -o 'jsonpath={.status.addresses[?(@.type=="InternalIP")].address}')
test "$out" = 10.240.0.10 || fail "unexpected node InternalIP: $out"

kubectl apply -f - >"$work/apply-pods" 2>&1 <<'EOF' || fail "could not create pods: $(cat "$work/apply-pods")"
apiVersion: v1
kind: Pod
metadata:
  name: fake-pod
  namespace: default
spec:
  nodeName: kwok-node-0
  containers:
    - name: app
      image: example.invalid/app:1
---
apiVersion: v1
kind: Pod
metadata:
  name: unmanaged-pod
  namespace: default
spec:
  nodeName: unmanaged-node
  containers:
    - name: app
      image: example.invalid/app:1
EOF

kubectl wait --for=condition=Ready pod/fake-pod --timeout=90s >"$work/wait-pod" 2>&1 ||
  fail "pod on the fake node did not become Ready: $(cat "$work/wait-pod")"
out=$(kubectl get pod fake-pod -o 'jsonpath={.status.phase} {.status.podIP} {.status.hostIP}')
case $out in
  "Running 10.244.0."*" 10.240.0.10") ;;
  *) fail "unexpected fake pod status: $out" ;;
esac

# Negative: a node without the annotation and its pod are left alone.
out=$(kubectl get node unmanaged-node -o 'jsonpath={.status.conditions[?(@.type=="Ready")].status}')
test -z "$out" || fail "unmanaged node was given a Ready condition: $out"
out=$(kubectl get pod unmanaged-pod -o 'jsonpath={.status.phase}')
test "$out" = Pending || fail "pod on the unmanaged node did not stay Pending: $out"

# Deletion completes without a kubelet because the pod-delete stage removes the pod.
kubectl delete pod fake-pod --timeout=60s >"$work/delete" 2>&1 ||
  fail "fake pod deletion did not complete: $(cat "$work/delete")"
if kubectl get pod fake-pod >/dev/null 2>&1; then
  fail 'fake pod still exists after deletion'
fi

docker inspect -f '{{.State.Running}}' "$kwok" | grep -Fx true >/dev/null ||
  fail 'kwok controller exited'

printf 'SMOKE PASS\n'
