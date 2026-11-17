#!/bin/sh
set -eu

# The adapter is an aggregated API server: it lists HPAs and ScalingSchedules
# from a real control plane (Verity etcd and kube-apiserver),
# computes the referenced metric, and serves it on the custom metrics API with
# authentication and authorization delegated to that control plane.
# kubectl manages the control plane and curl queries the adapter; all helper
# images are pinned by digest.

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

etcd_index=ghcr.io/tektum/etcd@sha256:fc322841b20ac374159333e013fb417aa712e776380c53dc34ab8a1958c07fd2
api_index=ghcr.io/tektum/kube-apiserver@sha256:b46742424f608bb186b83390c41cbe7f97df411ae3cf8fc3e4578c096a6b57bd
kubectl_index=ghcr.io/tektum/kubectl@sha256:537780af388652be3a0130aacd6d1cfed24704ab6a820c6c7024602ec7777332
curl_index=docker.io/curlimages/curl:8.14.1@sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b

id=$$
network="verity-kma-$id"
etcd="verity-kma-etcd-$id"
api="verity-kma-api-$id"
adapter="verity-kma-adapter-$id"
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  docker logs "$adapter" 2>&1 | tail -n 40 >&2 || true
  docker logs "$api" 2>&1 | tail -n 20 >&2 || true
  exit 1
}

cleanup() {
  docker rm -f "$adapter" "$api" "$etcd" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'

inspect() {
  docker image inspect --format "$1" "$image"
}
[ "$(inspect '{{.Config.User}}')" = 65532 ] || fail "unexpected OCI user: $(inspect '{{.Config.User}}')"
[ "$(inspect '{{json .Config.Entrypoint}}')" = '["/usr/bin/kube-metrics-adapter"]' ] ||
  fail "unexpected entrypoint: $(inspect '{{json .Config.Entrypoint}}')"
[ "$(inspect '{{json .Config.Cmd}}')" = null ] ||
  fail "unexpected default command: $(inspect '{{json .Config.Cmd}}')"
[ "$(inspect '{{.Config.WorkingDir}}')" = /home/nonroot ] ||
  fail "unexpected working directory: $(inspect '{{.Config.WorkingDir}}')"

run() {
  docker run --rm --read-only --cap-drop=ALL --security-opt=no-new-privileges "$@"
}

# The binary records the pinned upstream release as its Go main module, which
# is also the version the scanner reads.
docker create --name "$adapter" "$image" >/dev/null || fail 'cannot create a container'
docker cp "$adapter:/usr/bin/kube-metrics-adapter" "$work/binary" >/dev/null ||
  fail 'cannot copy /usr/bin/kube-metrics-adapter'
docker rm "$adapter" >/dev/null
module=$(printf 'mod\tgithub.com/zalando-incubator/kube-metrics-adapter\tv%s' "$expected_version")
LC_ALL=C grep -aF "$module" "$work/binary" >/dev/null ||
  fail "binary does not embed main module v$expected_version"
rm -f "$work/binary"

run --network none "$image" --help >"$work/help" 2>&1 ||
  fail "--help failed: $(cat "$work/help")"
for flag in --lister-kubeconfig --authentication-kubeconfig --authorization-kubeconfig \
  --secure-port --cert-dir --prometheus-server --scaling-schedule --enable-custom-metrics-api \
  --enable-external-metrics-api; do
  grep -F -e "$flag " "$work/help" >/dev/null || fail "help is missing $flag"
done

# Negative: an unknown flag is rejected before anything starts.
status=0
run --network none "$image" --definitely-invalid >"$work/invalid" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail 'unknown flag unexpectedly succeeded'
grep -Fx 'Error: unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail "unknown flag diagnostic is missing: $(cat "$work/invalid")"

# Negative: a missing lister kubeconfig, and no kubeconfig outside a cluster,
# stop the adapter with the upstream configuration errors instead of serving.
status=0
run --network none "$image" --secure-port=6443 --lister-kubeconfig=/nonexistent/kubeconfig \
  >"$work/missing" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail 'missing kubeconfig unexpectedly succeeded'
grep -F 'unable to construct lister client config to initialize provider: stat /nonexistent/kubeconfig: no such file or directory' \
  "$work/missing" >/dev/null || fail "missing kubeconfig diagnostic: $(cat "$work/missing")"
status=0
run --network none "$image" --secure-port=6443 >"$work/incluster" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail 'out-of-cluster start unexpectedly succeeded'
grep -F 'unable to load in-cluster configuration, KUBERNETES_SERVICE_HOST and KUBERNETES_SERVICE_PORT must be defined' \
  "$work/incluster" >/dev/null || fail "in-cluster diagnostic: $(cat "$work/incluster")"

# Control plane with a static admin token.
mkdir -p "$work/pki" "$work/kube"
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
chmod 0644 "$work/pki/sa.key" "$work/pki/tokens.csv" "$work/kube/config"

# pull_child INDEX: pull the pinned index by its per-platform child digest,
# verifying the index bytes against the pin first so the pin stays authoritative.
# The publish job runs this test per architecture against one daemon, so an
# index digest must never be passed straight to docker run.
image_arch=$(inspect '{{.Architecture}}')
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
curl_image=$(pull_child "$curl_index")

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

# request PATH [TOKEN]: GET PATH from the adapter, anonymously without TOKEN.
# The body goes to $work/body and the HTTP status code to stdout.
request() {
  if [ -n "${2:-}" ]; then
    set -- "$1" -H "Authorization: Bearer $2"
  else
    set -- "$1"
  fi
  path=$1
  shift
  docker run --rm --network "$network" "$curl_image" -sk --max-time 10 \
    -w '\n%{http_code}' "$@" "https://$adapter:6443$path" >"$work/response" 2>&1 || true
  sed '$d' "$work/response" >"$work/body"
  tail -n 1 "$work/response"
}

i=0
until kubectl get --raw /readyz >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'kube-apiserver did not become ready'
  sleep 2
done

# A ScalingSchedule whose one-time event is active now, referenced by an HPA
# Object metric. With a zero scaling window the metric is the event value.
start=$(date -u -d '@'"$(($(date +%s) - 120))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) ||
  start=$(date -u -r "$(($(date +%s) - 120))" +%Y-%m-%dT%H:%M:%SZ)
kubectl apply -f - >"$work/apply" 2>&1 <<EOF || fail "could not create fixtures: $(cat "$work/apply")"
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: scalingschedules.zalando.org
spec:
  group: zalando.org
  names: {kind: ScalingSchedule, listKind: ScalingScheduleList, plural: scalingschedules, singular: scalingschedule}
  scope: Namespaced
  versions:
    - name: v1
      served: true
      storage: true
      subresources: {status: {}}
      schema:
        openAPIV3Schema: {type: object, x-kubernetes-preserve-unknown-fields: true}
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: clusterscalingschedules.zalando.org
spec:
  group: zalando.org
  names: {kind: ClusterScalingSchedule, listKind: ClusterScalingScheduleList, plural: clusterscalingschedules, singular: clusterscalingschedule}
  scope: Cluster
  versions:
    - name: v1
      served: true
      storage: true
      subresources: {status: {}}
      schema:
        openAPIV3Schema: {type: object, x-kubernetes-preserve-unknown-fields: true}
---
apiVersion: v1
kind: Namespace
metadata:
  name: kma
EOF
i=0
until kubectl get scalingschedules.zalando.org -A >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail 'ScalingSchedule CRD was not established'
  sleep 1
done
kubectl apply -f - >"$work/apply" 2>&1 <<EOF || fail "could not create the HPA: $(cat "$work/apply")"
apiVersion: zalando.org/v1
kind: ScalingSchedule
metadata:
  name: peak
  namespace: kma
spec:
  schedules:
    - type: OneTime
      date: "$start"
      durationMinutes: 60
      value: 4242
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: kma
spec:
  replicas: 1
  selector:
    matchLabels: {app: web}
  template:
    metadata:
      labels: {app: web}
    spec:
      containers:
        - name: web
          image: registry.k8s.io/pause:3.10
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: web
  namespace: kma
spec:
  scaleTargetRef: {apiVersion: apps/v1, kind: Deployment, name: web}
  minReplicas: 1
  maxReplicas: 10
  metrics:
    - type: Object
      object:
        describedObject: {apiVersion: zalando.org/v1, kind: ScalingSchedule, name: peak}
        metric: {name: peak}
        target: {type: Value, value: "1000"}
EOF

# The adapter runs out of cluster on a read-only root filesystem. Its working
# directory is a tmpfs, so the default relative --cert-dir holds the generated
# self-signed serving certificate.
docker run -d --name "$adapter" --network "$network" --read-only --cap-drop=ALL \
  --security-opt=no-new-privileges --tmpfs /home/nonroot:uid=65532,gid=65532 \
  -v "$work/kube:/kube:ro" "$image" \
  --secure-port=6443 \
  --lister-kubeconfig=/kube/config \
  --authentication-kubeconfig=/kube/config \
  --authorization-kubeconfig=/kube/config \
  --scaling-schedule --scaling-schedule-default-scaling-window=0 \
  --resource-update-interval=2s --default-collection-interval=2s >/dev/null ||
  fail 'adapter did not start'

i=0
until [ "$(request /readyz)" = 200 ] && [ "$(cat "$work/body")" = ok ]; do
  [ "$(docker inspect --format '{{.State.Running}}' "$adapter")" = true ] ||
    fail 'adapter exited before becoming ready'
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'adapter did not become ready'
  sleep 2
done

# The adapter serves the schedule value for the object the HPA references.
# Authentication is a TokenReview and authorization a SubjectAccessReview
# against the control plane.
metric_path=/apis/custom.metrics.k8s.io/v1beta2/namespaces/kma/scalingschedules.zalando.org/peak/peak
i=0
until [ "$(request "$metric_path" "$token")" = 200 ]; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail "metric was never served: $(cat "$work/response")"
  sleep 2
done
jq -e '.kind == "MetricValueList" and (.items | length) == 1
  and .items[0].describedObject.kind == "ScalingSchedule"
  and .items[0].describedObject.namespace == "kma"
  and .items[0].describedObject.name == "peak"
  and .items[0].metric.name == "peak"
  and .items[0].value == "4242"' "$work/body" >/dev/null ||
  fail "unexpected metric value: $(cat "$work/body")"

status=$(request /apis/custom.metrics.k8s.io/v1beta2 "$token")
[ "$status" = 200 ] || fail "custom metrics discovery returned $status: $(cat "$work/body")"
jq -e '.kind == "APIResourceList" and .groupVersion == "custom.metrics.k8s.io/v1beta2"
  and any(.resources[]; .name == "scalingschedules.zalando.org/peak")' "$work/body" >/dev/null ||
  fail "custom metrics discovery lacks the schedule metric: $(cat "$work/body")"
status=$(request /apis/external.metrics.k8s.io/v1beta1 "$token")
[ "$status" = 200 ] || fail "external metrics discovery returned $status: $(cat "$work/body")"
jq -e '.kind == "APIResourceList" and .groupVersion == "external.metrics.k8s.io/v1beta1"' \
  "$work/body" >/dev/null || fail "unexpected external metrics discovery: $(cat "$work/body")"

# Negative: an anonymous request for the metric is forbidden, an unknown
# token is rejected by the control plane, and an object no HPA references has
# no metric.
status=$(request "$metric_path")
[ "$status" = 403 ] || fail "anonymous metric request returned $status: $(cat "$work/body")"
jq -e '.reason == "Forbidden" and (.message | contains("system:anonymous"))' "$work/body" >/dev/null ||
  fail "anonymous request was not forbidden: $(cat "$work/body")"
status=$(request "$metric_path" "not-$token")
[ "$status" = 401 ] || fail "unknown token returned $status: $(cat "$work/body")"
status=$(request /apis/custom.metrics.k8s.io/v1beta2/namespaces/kma/scalingschedules.zalando.org/absent/peak "$token")
[ "$status" = 404 ] || fail "unknown object returned $status: $(cat "$work/body")"
jq -e '.reason == "NotFound"' "$work/body" >/dev/null ||
  fail "unknown object did not return NotFound: $(cat "$work/body")"

# The scheduled scaling controller writes the active state back to the
# control plane.
i=0
until [ "$(kubectl get scalingschedules.zalando.org peak -n kma -o jsonpath='{.status.active}' 2>/dev/null)" = true ]; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail 'ScalingSchedule status.active was never set'
  sleep 2
done

printf 'SMOKE PASS version=%s\n' "$expected_version"
