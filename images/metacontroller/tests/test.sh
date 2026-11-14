#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# Peers for a real control plane: Verity etcd 3.7, kube-apiserver 1.37 and
# kubectl 1.35, and Python 3.13 for the sync webhook, pinned by digest.
etcd_index=ghcr.io/tektum/etcd@sha256:0a459e90afc2f3d96a4fa39ae40aa10593fa7667110c3985ddc0b11f0d5635a3
api_index=ghcr.io/tektum/kube-apiserver@sha256:de3b635d1f7476820e957fbd11d70b2b507ac7d3c69b98a6ea0694fc184a4023
kubectl_index=ghcr.io/tektum/kubectl@sha256:f8230567093c6f3bee4e6cb75b704813d729846d40c979961733d9389692f7ae
python_index=ghcr.io/tektum/python@sha256:d059268a2e4f0ef0cc82bb50c847e69e16e174736758013a153cb36311fa6dd6

id=$$
label="verity-test=metacontroller-$id"
network="verity-mc-$id"
etcd="verity-mc-etcd-$id"
api="verity-mc-api-$id"
hook="verity-mc-hook-$id"
mc="verity-mc-controller-$id"
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  for c in "$mc" "$hook" "$api"; do
    docker logs "$c" >/dev/null 2>&1 || continue
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

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/metacontroller"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'

run() {
  docker run --rm --label "$label" --network none --read-only --cap-drop=ALL "$@"
}

# CLI surface: flags the upstream manifests set, and an invalid flag.
run "$image" -h >"$work/help" 2>&1 || true
for flag in -discovery-interval -cache-flush-interval -metrics-address -health-probe-bind-address \
  -leader-election -apply-strategy -target-label-selector -zap-log-level -kubeconfig; do
  grep -F -e "  $flag" "$work/help" >/dev/null || fail "help is missing $flag"
done
status=0
run "$image" -definitely-invalid >"$work/invalid" 2>&1 || status=$?
test "$status" = 2 || fail "invalid flag exited $status, want 2"
grep -F 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"

# Outside a cluster the controller logs its build version, then refuses to start.
status=0
run "$image" >"$work/nocluster" 2>&1 || status=$?
test "$status" -ne 0 || fail 'controller outside a cluster unexpectedly succeeded'
grep -F "\"version\":\"$expected_version\"" "$work/nocluster" >/dev/null ||
  fail "version $expected_version is missing: $(cat "$work/nocluster")"
grep -F 'unable to load in-cluster configuration' "$work/nocluster" >/dev/null ||
  fail "in-cluster diagnostic is missing: $(cat "$work/nocluster")"

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
python_image=$(pull_child "$python_index")

# Control plane: etcd and kube-apiserver with static tokens for an admin and
# for metacontroller.
mkdir -p "$work/pki" "$work/kube" "$work/hook"
openssl genrsa -out "$work/pki/sa.key" 2048 2>/dev/null || fail 'could not generate the service account key'
newtoken() {
  od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
}
admin_token=$(newtoken)
mc_token=$(newtoken)
{
  printf '%s,verity-admin,verity-admin,system:masters\n' "$admin_token"
  printf '%s,metacontroller,metacontroller\n' "$mc_token"
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
kubeconfig "$mc_token" >"$work/kube/metacontroller"
chmod 0644 "$work/kube/admin" "$work/kube/metacontroller"

# kube-apiserver needs a default route to pick its advertise address, so this
# is a plain user network, as in the other control-plane tests.
docker network create --label "$label" "$network" >/dev/null
docker run -d --name "$etcd" --label "$label" --network "$network" \
  --tmpfs /var/lib/etcd:uid=65532,gid=65532 "$etcd_image" --data-dir=/var/lib/etcd/data \
  --listen-client-urls=http://0.0.0.0:2379 --advertise-client-urls="http://$etcd:2379" >/dev/null
docker run -d --name "$api" --label "$label" --network "$network" --tmpfs /tmp:uid=65532,gid=65532 \
  -v "$work/pki:/pki:ro" "$api_image" \
  --etcd-servers="http://$etcd:2379" --secure-port=6443 --cert-dir=/tmp \
  --token-auth-file=/pki/tokens.csv --authorization-mode=RBAC \
  --service-account-issuer=https://kubernetes.default.svc \
  --service-account-key-file=/pki/sa.key --service-account-signing-key-file=/pki/sa.key \
  --service-cluster-ip-range=10.96.0.0/16 >/dev/null

kubectl() {
  timeout 120 docker run --rm -i --label "$label" --network "$network" -v "$work/kube:/kube:ro" \
    -e KUBECONFIG=/kube/admin "$kubectl_image" "$@"
}

i=0
until kubectl get --raw /readyz >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'kube-apiserver did not become ready'
  sleep 2
done

# The metacontroller API types with the upstream approval annotation and
# permissive schemas (the upstream CRDs carry full OpenAPI schemas), a namespaced parent type, and RBAC as the upstream
# production manifest grants it.
kubectl apply -f - >"$work/apply" 2>&1 <<'EOF' || fail "could not create CRDs and RBAC: $(cat "$work/apply")"
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: compositecontrollers.metacontroller.k8s.io
  annotations:
    api-approved.kubernetes.io: unapproved, request not yet submitted
spec:
  group: metacontroller.k8s.io
  names: {kind: CompositeController, listKind: CompositeControllerList, plural: compositecontrollers, singular: compositecontroller}
  scope: Cluster
  versions:
    - name: v1alpha1
      served: true
      storage: true
      subresources: {status: {}}
      schema:
        openAPIV3Schema: {type: object, x-kubernetes-preserve-unknown-fields: true}
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: decoratorcontrollers.metacontroller.k8s.io
  annotations:
    api-approved.kubernetes.io: unapproved, request not yet submitted
spec:
  group: metacontroller.k8s.io
  names: {kind: DecoratorController, listKind: DecoratorControllerList, plural: decoratorcontrollers, singular: decoratorcontroller}
  scope: Cluster
  versions:
    - name: v1alpha1
      served: true
      storage: true
      subresources: {status: {}}
      schema:
        openAPIV3Schema: {type: object, x-kubernetes-preserve-unknown-fields: true}
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: controllerrevisions.metacontroller.k8s.io
  annotations:
    api-approved.kubernetes.io: unapproved, request not yet submitted
spec:
  group: metacontroller.k8s.io
  names: {kind: ControllerRevision, listKind: ControllerRevisionList, plural: controllerrevisions, singular: controllerrevision}
  scope: Namespaced
  versions:
    - name: v1alpha1
      served: true
      storage: true
      schema:
        openAPIV3Schema: {type: object, x-kubernetes-preserve-unknown-fields: true}
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: greeters.example.verity.test
spec:
  group: example.verity.test
  names: {kind: Greeter, listKind: GreeterList, plural: greeters, singular: greeter}
  scope: Namespaced
  versions:
    - name: v1
      served: true
      storage: true
      subresources: {status: {}}
      schema:
        openAPIV3Schema: {type: object, x-kubernetes-preserve-unknown-fields: true}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: metacontroller
rules:
  - apiGroups: ["*"]
    resources: ["*"]
    verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: metacontroller
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: metacontroller
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: metacontroller
EOF
kubectl wait --for condition=established --timeout=60s \
  crd/compositecontrollers.metacontroller.k8s.io crd/decoratorcontrollers.metacontroller.k8s.io \
  crd/controllerrevisions.metacontroller.k8s.io crd/greeters.example.verity.test >/dev/null ||
  fail 'CRDs did not become established'

# Sync webhook: a Greeter with spec.who owns one ConfigMap that greets it; a
# Greeter without spec.who owns nothing. The hook logs each parent it syncs.
cat >"$work/hook/hook.py" <<'EOF'
import json
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        parent = request["parent"]
        name = parent["metadata"]["name"]
        who = parent.get("spec", {}).get("who", "")
        children = []
        if who:
            children.append({
                "apiVersion": "v1",
                "kind": "ConfigMap",
                "metadata": {"name": name + "-greeting"},
                "data": {"greeting": "Hello, " + who},
            })
        body = json.dumps({"status": {"observedWho": who, "children": len(children)},
                           "children": children}).encode()
        print("sync", parent["metadata"]["namespace"], name, repr(who), flush=True)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
EOF
chmod 0755 "$work/hook"
chmod 0644 "$work/hook/hook.py"
docker run -d --name "$hook" --label "$label" --network "$network" --read-only --cap-drop=ALL \
  --user 65532:65532 -v "$work/hook:/hook:ro" "$python_image" -u /hook/hook.py >/dev/null

# metacontroller with its own non-admin token, read-only root, no capabilities.
docker run -d --name "$mc" --label "$label" --network "$network" --read-only --cap-drop=ALL \
  -v "$work/kube:/kube:ro" -e KUBECONFIG=/kube/metacontroller "$image" \
  --zap-log-level=4 --discovery-interval=2s >/dev/null

# Probes answer on the documented ports; the hook container has an HTTP client.
probe() {
  docker exec "$hook" python3 -c '
import sys, urllib.request
print(urllib.request.urlopen(sys.argv[1], timeout=5).read().decode())' "$1"
}
i=0
until probe "http://$mc:8081/readyz" >"$work/readyz" 2>&1; do
  i=$((i + 1))
  [ "$(docker inspect -f '{{.State.Running}}' "$mc")" = true ] || fail 'metacontroller exited early'
  [ "$i" -lt 60 ] || fail "metacontroller did not become ready: $(cat "$work/readyz")"
  sleep 2
done
grep -Fx ok "$work/readyz" >/dev/null || fail "unexpected readyz body: $(cat "$work/readyz")"

kubectl apply -f - >"$work/cc" 2>&1 <<EOF || fail "could not create the CompositeController: $(cat "$work/cc")"
apiVersion: metacontroller.k8s.io/v1alpha1
kind: CompositeController
metadata:
  name: greeter-controller
spec:
  generateSelector: true
  resyncPeriodSeconds: 5
  parentResource:
    apiVersion: example.verity.test/v1
    resource: greeters
  childResources:
    - apiVersion: v1
      resource: configmaps
      updateStrategy:
        method: InPlace
  hooks:
    sync:
      webhook:
        url: http://$hook:8080/sync
EOF

kubectl apply -f - >"$work/parent" 2>&1 <<'EOF' || fail "could not create the parent: $(cat "$work/parent")"
apiVersion: example.verity.test/v1
kind: Greeter
metadata:
  name: hello
  namespace: default
spec:
  who: verity
EOF

# wait_for DESCRIPTION EXPECTED KUBECTL-ARGS...: poll until kubectl prints EXPECTED.
wait_for() {
  what=$1
  want=$2
  shift 2
  i=0
  # kubectl must succeed: an error must not pass as an empty expected value.
  until out=$(kubectl "$@" 2>/dev/null) && [ "$out" = "$want" ]; do
    i=$((i + 1))
    [ "$i" -lt 60 ] || fail "$what: want '$want', got '$(kubectl "$@" 2>&1)'"
    sleep 2
  done
}

wait_for 'child ConfigMap was not created' 'Hello, verity' \
  get configmap hello-greeting -n default -o 'jsonpath={.data.greeting}'
owner=$(kubectl get configmap hello-greeting -n default \
  -o 'jsonpath={.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}/{.metadata.ownerReferences[0].controller}')
test "$owner" = Greeter/hello/true || fail "child is not controlled by its parent: $owner"
parent_uid=$(kubectl get greeter hello -n default -o 'jsonpath={.metadata.uid}')
child_owner_uid=$(kubectl get configmap hello-greeting -n default -o 'jsonpath={.metadata.ownerReferences[0].uid}')
test "$child_owner_uid" = "$parent_uid" || fail 'child owner UID does not match the parent'
wait_for 'parent status was not written' 'verity/1' \
  get greeter hello -n default -o 'jsonpath={.status.observedWho}/{.status.children}'
grep -F "sync default hello 'verity'" "$(docker logs "$hook" >"$work/hook.log" 2>&1; echo "$work/hook.log")" \
  >/dev/null || fail 'the sync hook was not called for the parent'

# A spec change is reconciled into the existing child.
kubectl patch greeter hello -n default --type merge -p '{"spec":{"who":"metacontroller"}}' >/dev/null ||
  fail 'could not update the parent'
wait_for 'child ConfigMap was not updated' 'Hello, metacontroller' \
  get configmap hello-greeting -n default -o 'jsonpath={.data.greeting}'

# Negative: a child the hook no longer returns is deleted by metacontroller.
kubectl patch greeter hello -n default --type json -p '[{"op":"remove","path":"/spec/who"}]' >/dev/null ||
  fail 'could not clear the parent'
wait_for 'orphaned child was not deleted' '' \
  get configmap hello-greeting -n default --ignore-not-found -o name
wait_for 'parent status did not drop the child' '/0' \
  get greeter hello -n default -o 'jsonpath={.status.observedWho}/{.status.children}'

probe "http://$mc:9999/metrics" >"$work/metrics" 2>&1 || fail "metrics endpoint failed: $(cat "$work/metrics")"
grep -E '^controller_runtime_|^workqueue_|^metacontroller_' "$work/metrics" >/dev/null ||
  fail 'metrics endpoint has no controller metrics'

echo 'SMOKE PASS'
