#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# Peers for a real control plane: Verity etcd 3.7, kube-apiserver 1.37 and
# kubectl 1.35, pinned by digest. No scheduler or kubelet runs, so the Ray pods
# the operator creates stay Pending; the operator's own work is fully visible.
etcd_index=ghcr.io/tektum/etcd@sha256:fc322841b20ac374159333e013fb417aa712e776380c53dc34ab8a1958c07fd2
api_index=ghcr.io/tektum/kube-apiserver@sha256:b46742424f608bb186b83390c41cbe7f97df411ae3cf8fc3e4578c096a6b57bd
kubectl_index=ghcr.io/tektum/kubectl@sha256:537780af388652be3a0130aacd6d1cfed24704ab6a820c6c7024602ec7777332

id=$$
network="verity-kuberay-$id"
etcd="verity-kuberay-etcd-$id"
api="verity-kuberay-api-$id"
op="verity-kuberay-op-$id"
work=$(mktemp -d)
ns=ray-system
other=ray-unwatched
ray_image=example.invalid/ray:smoke

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
  '["/usr/bin/kuberay-operator"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = / ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'CA bundle environment is missing'

# The upstream Helm chart runs read-only as non-root with every capability dropped.
run() {
  docker run --rm --network none --read-only --cap-drop=ALL "$@"
}

# CLI surface: Go flag parsing, as upstream. Every flag the Helm chart passes.
run "$image" --help >"$work/help" 2>&1 || fail "help failed: $(cat "$work/help")"
grep -F 'Usage of /usr/bin/kuberay-operator:' "$work/help" >/dev/null ||
  fail "help usage line is missing: $(head -n 1 "$work/help")"
for flag in -batch-scheduler -burst -config -enable-batch-scheduler -enable-leader-election \
  -enable-metrics -feature-gates -health-probe-bind-address -kubeconfig \
  -leader-election-namespace -log-file-encoder -log-file-path -log-stdout-encoder \
  -metrics-addr -qps -reconcile-concurrency -use-kubernetes-proxy -watch-namespace \
  -zap-log-level; do
  grep -E -e "^  $flag( |\$)" "$work/help" >/dev/null || fail "help is missing $flag"
done
status=0
run "$image" --definitely-invalid >"$work/invalid" 2>&1 || status=$?
test "$status" -eq 2 || fail "invalid flag exited $status, want 2"
grep -F 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"

# Upstream's image and the Helm chart (operatorCommand) run /manager.
run --entrypoint /manager "$image" --help >"$work/manager" 2>&1 ||
  fail "compatibility path /manager does not run: $(cat "$work/manager")"
grep -F -e '-watch-namespace' "$work/manager" >/dev/null ||
  fail 'compatibility path /manager printed no flag help'

# Invalid settings fail before any cluster access, with the operator's diagnostic.
status=0
run "$image" --feature-gates=NoSuchGate=true >"$work/gate" 2>&1 || status=$?
test "$status" -eq 1 || fail "unknown feature gate exited $status, want 1"
grep -F 'unrecognized feature gate: NoSuchGate' "$work/gate" >/dev/null ||
  fail "feature gate diagnostic is missing: $(cat "$work/gate")"
status=0
run "$image" --batch-scheduler=no-such-scheduler >"$work/scheduler" 2>&1 || status=$?
test "$status" -eq 1 || fail "unknown batch scheduler exited $status, want 1"
grep -F 'scheduler is not supported, name=no-such-scheduler' "$work/scheduler" >/dev/null ||
  fail "batch scheduler diagnostic is missing: $(cat "$work/scheduler")"

# Without any cluster configuration the operator fails fast instead of hanging.
status=0
timeout 60 docker run --rm --network none --read-only --cap-drop=ALL "$image" \
  >"$work/nocluster" 2>&1 || status=$?
test "$status" -ne 124 || fail 'operator hung outside a cluster instead of failing'
test "$status" -eq 1 || fail "operator outside a cluster exited $status, want 1"
for line in 'KUBERNETES_SERVICE_HOST and KUBERNETES_SERVICE_PORT must be defined' \
  'unable to get kubeconfig'; do
  grep -F "$line" "$work/nocluster" >/dev/null ||
    fail "no-cluster diagnostic is missing $line: $(cat "$work/nocluster")"
done

# The Helm chart's configuration.enabled mode passes --config; a structured
# config replaces the flags and is validated before cluster access.
mkdir -p "$work/config"
cat >"$work/config/config.yaml" <<'EOF'
apiVersion: config.ray.io/v1alpha1
kind: Configuration
watchNamespace: ray-a,ray-b
EOF
cat >"$work/config/bad.yaml" <<'EOF'
apiVersion: config.ray.io/v1alpha1
kind: Configuration
batchScheduler: no-such-scheduler
EOF
chmod 0755 "$work/config"
chmod 0644 "$work/config/config.yaml" "$work/config/bad.yaml"
status=0
run -v "$work/config:/etc/kuberay:ro" "$image" --config /etc/kuberay/config.yaml \
  --watch-namespace=ignored-flag >"$work/configured" 2>&1 || status=$?
test "$status" -eq 1 || fail "configured operator outside a cluster exited $status, want 1"
grep -F '"namespaces":["ray-a","ray-b"]' "$work/configured" >/dev/null ||
  fail "config file namespaces were not applied: $(cat "$work/configured")"
if grep -F 'ignored-flag' "$work/configured" >/dev/null; then
  fail 'a flag overrode the config file'
fi
status=0
run -v "$work/config:/etc/kuberay:ro" "$image" --config /etc/kuberay/bad.yaml \
  >"$work/badconfig" 2>&1 || status=$?
test "$status" -eq 1 || fail "invalid config file exited $status, want 1"
grep -F 'scheduler is not supported, name=no-such-scheduler' "$work/badconfig" >/dev/null ||
  fail "config file validation diagnostic is missing: $(cat "$work/badconfig")"

# The image ships the CRDs generated for this build; install exactly those.
mkdir -p "$work/crds"
holder=$(docker create "$image") || fail 'could not create a container to copy the CRDs'
docker cp "$holder:/usr/share/kuberay-operator/crds/." "$work/crds/" >/dev/null 2>&1 ||
  { docker rm "$holder" >/dev/null; fail 'image does not ship /usr/share/kuberay-operator/crds'; }
docker rm "$holder" >/dev/null
for crd in rayclusters raycronjobs rayjobs rayservices; do
  [ -s "$work/crds/ray.io_$crd.yaml" ] || fail "missing CRD ray.io_$crd.yaml"
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
  docker run --rm -i --network "$network" -v "$work/kube:/kube:ro" -v "$work/crds:/crds:ro" \
    -e KUBECONFIG=/kube/config "$kubectl_image" "$@"
}

i=0
until kubectl get --raw /readyz >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'kube-apiserver did not become ready'
  sleep 2
done

# The RayCluster CRD exceeds the client-side apply annotation limit.
kubectl create -f /crds >"$work/crd" 2>&1 || fail "could not create the CRDs: $(cat "$work/crd")"
kubectl wait --for=condition=Established --timeout=60s crd/rayclusters.ray.io \
  crd/raycronjobs.ray.io crd/rayjobs.ray.io crd/rayservices.ray.io >"$work/established" 2>&1 ||
  fail "CRDs not established: $(cat "$work/established")"

# No controller manager runs, so create the default service accounts pods need.
kubectl apply -f - >"$work/apply" 2>&1 <<EOF || fail "could not create fixtures: $(cat "$work/apply")"
apiVersion: v1
kind: Namespace
metadata:
  name: $ns
---
apiVersion: v1
kind: Namespace
metadata:
  name: $other
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
  namespace: $ns
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
  namespace: $other
EOF

# Out of cluster with a kubeconfig, as the Helm chart's flags run it: read-only
# root, no capabilities, leader election, metrics, and one watched namespace.
docker run -d --name "$op" --network "$network" --read-only --cap-drop=ALL \
  -p 127.0.0.1::8080 -p 127.0.0.1::8082 \
  -v "$work/kube:/kube:ro" -e KUBECONFIG=/kube/config \
  "$image" --enable-leader-election --leader-election-namespace="$ns" \
  --watch-namespace="$ns" --enable-metrics --metrics-addr=:8080 \
  --health-probe-bind-address=:8082 --log-stdout-encoder=json >/dev/null

probe=$(docker port "$op" 8082/tcp | head -n 1)
metrics=$(docker port "$op" 8080/tcp | head -n 1)
[ -n "$probe" ] && [ -n "$metrics" ] || fail 'probe or metrics port is not published'
i=0
until curl -fsS "http://$probe/readyz" >"$work/readyz" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'operator did not become ready'
  [ "$(docker inspect --format '{{.State.Running}}' "$op")" = true ] ||
    fail 'operator exited before becoming ready'
  sleep 2
done
test "$(cat "$work/readyz")" = ok || fail "unexpected readyz body: $(cat "$work/readyz")"
curl -fsS "http://$probe/healthz" >"$work/healthz" || fail 'healthz failed'
test "$(cat "$work/healthz")" = ok || fail "unexpected healthz body: $(cat "$work/healthz")"

i=0
until kubectl get lease -n "$ns" ray-operator-leader \
  -o 'jsonpath={.spec.holderIdentity}' >"$work/holder" 2>/dev/null && [ -s "$work/holder" ]; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'operator did not acquire its leader election lease'
  sleep 2
done

# The shipped CRD schema rejects a RayCluster without a head group.
status=0
kubectl apply -f - >"$work/nohead" 2>&1 <<EOF || status=$?
apiVersion: ray.io/v1
kind: RayCluster
metadata:
  name: nohead
  namespace: $ns
spec:
  rayVersion: "2.52.0"
EOF
test "$status" -ne 0 || fail 'a RayCluster without headGroupSpec was accepted'
grep -F 'headGroupSpec' "$work/nohead" >/dev/null ||
  fail "CRD validation diagnostic is missing: $(cat "$work/nohead")"

# rayclusterspec NAME NAMESPACE MIN MAX: one head and one worker group.
rayclusterspec() {
  cat <<EOF
apiVersion: ray.io/v1
kind: RayCluster
metadata:
  name: $1
  namespace: $2
spec:
  rayVersion: "2.52.0"
  headGroupSpec:
    rayStartParams: {}
    template:
      spec:
        containers:
          - name: ray-head
            image: $ray_image
  workerGroupSpecs:
    - groupName: workers
      replicas: 1
      minReplicas: $3
      maxReplicas: $4
      rayStartParams: {}
      template:
        spec:
          containers:
            - name: ray-worker
              image: $ray_image
EOF
}
{
  rayclusterspec smoke "$ns" 1 1
  echo ---
  rayclusterspec invalid "$ns" 3 1
  echo ---
  rayclusterspec unwatched "$other" 1 1
} | kubectl apply -f - >"$work/rayclusters" 2>&1 ||
  fail "could not create the RayClusters: $(cat "$work/rayclusters")"

# The operator reconciles the watched RayCluster into a head Service, a head
# Pod stamped with this release's version, and a worker Pod joining the head.
pods() {
  kubectl get pods -n "$1" -l "ray.io/cluster=$2" -o json >"$work/pods.json" 2>/dev/null
}
i=0
until pods "$ns" smoke &&
  [ "$(jq '[.items[] | select(.metadata.labels["ray.io/node-type"] == "head")] | length' "$work/pods.json")" = 1 ] &&
  [ "$(jq '[.items[] | select(.metadata.labels["ray.io/node-type"] == "worker")] | length' "$work/pods.json")" = 1 ]; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail "operator did not create the head and worker pods: $(jq -c '[.items[]?.metadata.name]' "$work/pods.json")"
  sleep 2
done
for type in head worker; do
  jq -e --arg type "$type" --arg image "$ray_image" '
    [.items[] | select(.metadata.labels["ray.io/node-type"] == $type)][0]
    | .spec.containers[0].image == $image
      and .metadata.ownerReferences[0].kind == "RayCluster"
      and .metadata.ownerReferences[0].name == "smoke"' "$work/pods.json" >/dev/null ||
    fail "unexpected $type pod: $(jq -c --arg type "$type" '[.items[] | select(.metadata.labels["ray.io/node-type"] == $type)][0].metadata' "$work/pods.json")"
done
jq -e --arg version "v$expected_version" '[.items[] | select(.metadata.labels["ray.io/node-type"] == "head")][0]
  | .metadata.annotations["ray.io/kuberay-version"] == $version' "$work/pods.json" >/dev/null ||
  fail "head pod is not stamped with v$expected_version: $(jq -c '[.items[] | select(.metadata.labels["ray.io/node-type"] == "head")][0].metadata.annotations' "$work/pods.json")"
jq -e --arg address "--address=smoke-head-svc.$ns.svc.cluster.local:6379" '
  [.items[] | select(.metadata.labels["ray.io/node-type"] == "worker")][0].spec.containers[0]
  | (.command // []) + (.args // []) | join(" ") | contains("ray start") and contains($address)' \
  "$work/pods.json" >/dev/null ||
  fail "worker does not join the head service: $(jq -c '[.items[] | select(.metadata.labels["ray.io/node-type"] == "worker")][0].spec.containers[0] | [.command, .args]' "$work/pods.json")"
kubectl get service -n "$ns" smoke-head-svc -o json >"$work/svc.json" 2>&1 ||
  fail "operator did not create the head service: $(cat "$work/svc.json")"
jq -e '[.spec.ports[].port] as $ports | ([6379, 8265, 10001] - $ports) == []
  and .spec.selector["ray.io/cluster"] == "smoke"
  and .spec.selector["ray.io/node-type"] == "head"' "$work/svc.json" >/dev/null ||
  fail "unexpected head service: $(jq -c '.spec' "$work/svc.json")"

i=0
until kubectl get raycluster -n "$ns" smoke -o json >"$work/smoke.json" 2>/dev/null &&
  jq -e '.status.desiredWorkerReplicas == 1
    and (.status.conditions // [] | any(.type == "HeadPodReady" and .status == "False"))' \
    "$work/smoke.json" >/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail "RayCluster status was not reconciled: $(jq -c '.status' "$work/smoke.json")"
  sleep 2
done

# An invalid spec is reported as an event and never produces pods.
i=0
until kubectl get events -n "$ns" --field-selector involvedObject.name=invalid -o json \
  >"$work/events.json" 2>/dev/null &&
  jq -e '.items | any(.reason == "InvalidRayClusterSpec"
    and (.message | contains("minReplicas 3 greater than maxReplicas 1")))' "$work/events.json" >/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail "no InvalidRayClusterSpec event: $(jq -c '[.items[]? | .reason + ": " + .message]' "$work/events.json")"
  sleep 2
done
pods "$ns" invalid || fail 'could not list pods of the invalid RayCluster'
test "$(jq '.items | length' "$work/pods.json")" = 0 || fail 'the invalid RayCluster got pods'

# A RayCluster outside the watched namespace is left alone.
pods "$other" unwatched || fail 'could not list pods of the unwatched RayCluster'
test "$(jq '.items | length' "$work/pods.json")" = 0 ||
  fail 'the operator reconciled a RayCluster outside its watched namespace'
if kubectl get service -n "$other" unwatched-head-svc >/dev/null 2>&1; then
  fail 'the operator created a service outside its watched namespace'
fi

curl -fsS "http://$metrics/metrics" >"$work/metrics" || fail 'metrics endpoint failed'
for pattern in \
  '^leader_election_master_status\{name="ray-operator-leader"\} 1$' \
  '^controller_runtime_reconcile_total\{controller="raycluster",result="(success|requeue|requeue_after)"\} [1-9]' \
  "^kuberay_cluster_info\\{[^}]*name=\"smoke\"[^}]*namespace=\"$ns\"[^}]*\\} 1\$"; do
  grep -E "$pattern" "$work/metrics" >/dev/null ||
    fail "metrics do not match $pattern: $(grep -E '^(leader_election|controller_runtime_reconcile_total|kuberay_)' "$work/metrics")"
done

# SIGTERM shuts the operator down cleanly.
docker stop --time 20 "$op" >/dev/null || fail 'could not stop the operator'
test "$(docker inspect --format '{{.State.ExitCode}}' "$op")" = 0 ||
  fail "operator exited $(docker inspect --format '{{.State.ExitCode}}' "$op") on SIGTERM"

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$expected_version"
