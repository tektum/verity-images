#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# Peers for a real control plane: Verity etcd, kube-apiserver and kubectl,
# pinned by digest.
etcd_index=ghcr.io/tektum/etcd@sha256:fc322841b20ac374159333e013fb417aa712e776380c53dc34ab8a1958c07fd2
api_index=ghcr.io/tektum/kube-apiserver@sha256:b46742424f608bb186b83390c41cbe7f97df411ae3cf8fc3e4578c096a6b57bd
kubectl_index=ghcr.io/tektum/kubectl@sha256:537780af388652be3a0130aacd6d1cfed24704ab6a820c6c7024602ec7777332

id=$$
network="verity-mlbc-$id"
etcd="verity-mlbc-etcd-$id"
api="verity-mlbc-api-$id"
controller="verity-mlbc-controller-$id"
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  for c in "$controller" "$api"; do
    printf -- '--- %s\n' "$c" >&2
    docker logs "$c" 2>&1 | tail -n 40 >&2 || true
  done
  exit 1
}

cleanup() {
  docker rm -f "$controller" "$api" "$etcd" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

recipe_value() {
  awk -v key="$1" '$1 == key { gsub(/"/, "", $2); print $2; exit }' "$2"
}
expected_version=$(recipe_value version: "$here/../melange.yaml")
expected_commit=$(recipe_value source-commit: "$here/../melange.yaml")
speaker_version=$(recipe_value version: "$here/../../metallb-speaker/melange.yaml")
speaker_commit=$(recipe_value source-commit: "$here/../../metallb-speaker/melange.yaml")
[ -n "$expected_version" ] && [ -n "$expected_commit" ] || fail 'could not read the recipe version'
# The controller and speaker must ship one MetalLB release.
test "$expected_version" = "$speaker_version" ||
  fail "controller $expected_version does not match metallb-speaker $speaker_version"
test "$expected_commit" = "$speaker_commit" ||
  fail "controller commit $expected_commit does not match metallb-speaker $speaker_commit"

test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/controller"]' ||
  fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'

run() {
  docker run --rm --network none --read-only --cap-drop=ALL --security-opt no-new-privileges "$@"
}

# CLI surface: the flags the upstream chart sets.
run "$image" --help >"$work/help" 2>&1 || true
for flag in -port -namespace -ml-secret-name -deployment -log-level -webhook-mode \
  -disable-cert-rotation -cert-service-name -lb-class -tls-min-version; do
  grep -E "^  $flag( |$)" "$work/help" >/dev/null || fail "help is missing $flag"
done

# Outside a cluster the controller logs its build identity, then refuses to start.
status=0
run "$image" --namespace smoke >"$work/nocluster" 2>&1 || status=$?
test "$status" -ne 0 || fail 'controller outside a cluster unexpectedly succeeded'
grep -F "MetalLB controller starting version $expected_version (commit $expected_commit, branch v$expected_version)" \
  "$work/nocluster" >/dev/null || fail "build identity is missing: $(cat "$work/nocluster")"
grep -F 'unable to get kubeconfig' "$work/nocluster" >/dev/null ||
  fail "kubeconfig diagnostic is missing: $(cat "$work/nocluster")"

# The MetalLB CRDs from the pinned source commit, verified by content.
crd_base="https://raw.githubusercontent.com/metallb/metallb/$expected_commit/config/crd/bases"
mkdir -p "$work/crds"
cat >"$work/crds/SHA256SUMS" <<'EOF'
b62589379612dcd4a0f267d65364e1acdf9870ca068dfbc2dd338c73757ea156  metallb.io_bfdprofiles.yaml
f4764d11511d15df85deb76fec9100e464944b5c909c175ebc3aef1a69b0b811  metallb.io_bgpadvertisements.yaml
dac1483cb53e361a427a7c40669fe9d08d8b86c13c5b7c1a5cff8c9ec13baf9b  metallb.io_bgppeers.yaml
c6bca6acc922264263ff2df35986453d55570adeda1560f4bc66926df853b6b6  metallb.io_communities.yaml
1b0b826a26a88ff3e4c8426a843b0057a52b6af13e333198375454fc8ac2d44d  metallb.io_configurationstates.yaml
585d55016cb9cf1aac3ed4a63b1075051bf8c20aab28dfcd3cfbe58a632ed230  metallb.io_ipaddresspools.yaml
ca8eb410b7bbd9517c8d864d6da2db145321c654259ba4865ce1dc617b035a3a  metallb.io_l2advertisements.yaml
3f236c79b22a7f89e9845221f025ee1a03c17673c0cd696fbf131b61ae3cd555  metallb.io_servicebgpstatuses.yaml
8f5703075435b55d229fdb72d8afdd3dc8d4167e7fa4ce65d9b08720e48c83cd  metallb.io_servicel2statuses.yaml
EOF
while read -r _ crd; do
  curl -fsSL --retry 3 -o "$work/crds/$crd" "$crd_base/$crd" || fail "cannot fetch $crd"
done <"$work/crds/SHA256SUMS"
(cd "$work/crds" && sha256sum -c --quiet SHA256SUMS) || fail 'CRD content does not match the pins'
chmod 0644 "$work/crds"/*.yaml

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

# Control plane: etcd and kube-apiserver with static tokens for an admin and
# the controller.
mkdir -p "$work/pki" "$work/kube"
openssl genrsa -out "$work/pki/sa.key" 2048 2>/dev/null || fail 'could not generate the service account key'
newtoken() {
  od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
}
admin_token=$(newtoken)
controller_token=$(newtoken)
{
  printf '%s,verity-admin,verity-admin,system:masters\n' "$admin_token"
  printf '%s,metallb-controller,metallb-controller\n' "$controller_token"
} >"$work/pki/tokens.csv"
chmod 0644 "$work/pki/sa.key" "$work/pki/tokens.csv"
kubeconfig() {
  cat <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: smoke
    cluster:
      server: https://$api:6443
      insecure-skip-tls-verify: true
users:
  - name: user
    user:
      token: $1
contexts:
  - name: smoke
    context:
      cluster: smoke
      user: user
current-context: smoke
EOF
}
kubeconfig "$admin_token" >"$work/kube/admin"
kubeconfig "$controller_token" >"$work/kube/controller"
chmod 0644 "$work/kube/admin" "$work/kube/controller"

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
    -e KUBECONFIG=/kube/admin "$kubectl_image" "$@"
}

i=0
until kubectl get --raw /readyz >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'kube-apiserver did not become ready'
  sleep 2
done

kubectl apply -f /crds >"$work/apply" 2>&1 || fail "could not create the CRDs: $(cat "$work/apply")"
kubectl wait --for=condition=Established --timeout=60s -f /crds >/dev/null 2>&1 ||
  fail 'the MetalLB CRDs did not become established'

# The controller ClusterRole and Role of the upstream chart at this commit
# (charts/metallb/templates/rbac.yaml, memberlist disabled), bound to the
# controller's user instead of its service account.
kubectl apply -f - >"$work/apply" 2>&1 <<'EOF' || fail "could not create the fixtures: $(cat "$work/apply")"
apiVersion: v1
kind: Namespace
metadata:
  name: metallb-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: metallb-controller
rules:
  - apiGroups: [""]
    resources: [services, namespaces]
    verbs: [get, list, watch]
  - apiGroups: [""]
    resources: [nodes]
    verbs: [list]
  - apiGroups: [""]
    resources: [services/status]
    verbs: [update]
  - apiGroups: [""]
    resources: [events]
    verbs: [create, patch]
  - apiGroups: [admissionregistration.k8s.io]
    resources: [validatingwebhookconfigurations]
    resourceNames: [metallb-webhook-configuration]
    verbs: [create, delete, get, list, patch, update, watch]
  - apiGroups: [admissionregistration.k8s.io]
    resources: [validatingwebhookconfigurations]
    verbs: [list, watch]
  - apiGroups: [apiextensions.k8s.io]
    resources: [customresourcedefinitions]
    resourceNames: [bfdprofiles.metallb.io, bgpadvertisements.metallb.io, bgppeers.metallb.io,
      ipaddresspools.metallb.io, l2advertisements.metallb.io, communities.metallb.io,
      configurationstates.metallb.io]
    verbs: [create, delete, get, list, patch, update, watch]
  - apiGroups: [apiextensions.k8s.io]
    resources: [customresourcedefinitions]
    verbs: [list, watch]
  - apiGroups: [metallb.io]
    resources: [configurationstates]
    verbs: [create, delete, get, list, patch, update, watch]
  - apiGroups: [metallb.io]
    resources: [configurationstates/status]
    verbs: [get, patch, update]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: metallb-controller
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: metallb-controller
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: metallb-controller
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: metallb-controller
  namespace: metallb-system
rules:
  - apiGroups: [""]
    resources: [secrets]
    verbs: [create, delete, get, list, patch, update, watch]
  - apiGroups: [metallb.io]
    resources: [ipaddresspools]
    verbs: [get, list, watch]
  - apiGroups: [metallb.io]
    resources: [ipaddresspools/status]
    verbs: [update]
  - apiGroups: [metallb.io]
    resources: [bgppeers, bgpadvertisements, l2advertisements]
    verbs: [get, list]
  - apiGroups: [metallb.io]
    resources: [communities, bfdprofiles]
    verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: metallb-controller
  namespace: metallb-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: metallb-controller
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: metallb-controller
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: smoke
  namespace: metallb-system
spec:
  addresses:
    - 192.0.2.10-192.0.2.11
---
apiVersion: v1
kind: Service
metadata:
  name: first
  namespace: default
spec:
  type: LoadBalancer
  ports:
    - port: 80
---
apiVersion: v1
kind: Service
metadata:
  name: pinned
  namespace: default
  annotations:
    metallb.io/loadBalancerIPs: 192.0.2.11
spec:
  type: LoadBalancer
  ports:
    - port: 80
EOF

# Out of cluster: the controller reaches the API server through a kubeconfig,
# with the webhook disabled because no Service fronts it here.
docker run -d --name "$controller" --network "$network" --read-only --cap-drop=ALL \
  --security-opt no-new-privileges -v "$work/kube:/kube:ro" -e KUBECONFIG=/kube/controller \
  "$image" --namespace=metallb-system --webhook-mode=disabled --log-level=debug >/dev/null

# lb_ip SERVICE: the first ingress address the controller wrote to its status.
lb_ip() {
  kubectl get service "$1" -o 'jsonpath={.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true
}
wait_ip() {
  i=0
  until [ "$(lb_ip "$1")" = "$2" ]; do
    [ "$(docker inspect --format '{{.State.Running}}' "$controller")" = true ] ||
      fail 'controller exited'
    i=$((i + 1))
    [ "$i" -lt 60 ] || fail "service $1 has address '$(lb_ip "$1")', want $2"
    sleep 2
  done
}
wait_ip pinned 192.0.2.11
wait_ip first 192.0.2.10

# The pool is exhausted: a third service stays pending with an allocation event.
kubectl create service loadbalancer third --tcp=80:80 >/dev/null || fail 'could not create service third'
i=0
until kubectl get events -n default --field-selector involvedObject.name=third \
  -o 'jsonpath={.items[*].reason}' 2>/dev/null | grep -F AllocationFailed >/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'no AllocationFailed event for service third'
  sleep 2
done
test -z "$(lb_ip third)" || fail "service third unexpectedly got $(lb_ip third)"

# Releasing an address lets the pending service take it.
kubectl delete service first >/dev/null || fail 'could not delete service first'
wait_ip third 192.0.2.10

docker logs "$controller" 2>&1 | grep -F "MetalLB controller starting version $expected_version" >/dev/null ||
  fail 'controller did not log its version'

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$expected_version"
