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
network="verity-kee-$id"
etcd="verity-kee-etcd-$id"
api="verity-kee-api-$id"
exporter="verity-kee-exp-$id"
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  for c in "$exporter" "$api"; do
    printf -- '--- %s\n' "$c" >&2
    docker logs "$c" 2>&1 | tail -n 30 >&2 || true
  done
  exit 1
}

cleanup() {
  docker rm -f "$exporter" "$api" "$etcd" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' "$here/../melange.yaml")
[ -n "$version" ] || fail 'could not read the recipe version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/kubernetes-event-exporter"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'

mkdir -p "$work/pki" "$work/kube" "$work/config" "$work/out"
chmod 0777 "$work/out"

run() {
  docker run --rm --network none --read-only --tmpfs /tmp --cap-drop=ALL \
    -v "$work/config:/config:ro" "$@"
}

# CLI surface.
run "$image" -h >"$work/help" 2>&1 || true
for flag in -conf -kubeconfig -metrics-address -metrics-tls-config; do
  grep -F -e "$flag" "$work/help" >/dev/null || fail "help is missing $flag: $(cat "$work/help")"
done

# Negative: an unknown flag is rejected.
status=0
run "$image" -definitely-invalid >"$work/invalid" 2>&1 || status=$?
test "$status" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"

# Negative: the default config path does not exist in the image.
status=0
run "$image" >"$work/noconf" 2>&1 || status=$?
test "$status" -ne 0 || fail 'missing config unexpectedly succeeded'
grep -F 'cannot read config file' "$work/noconf" >/dev/null ||
  fail "missing-config diagnostic is missing: $(cat "$work/noconf")"

# Negative: an invalid metrics name prefix fails config validation.
cat >"$work/config/bad.yaml" <<'EOF'
metricsNamePrefix: 1-bad
route:
  routes:
    - match:
        - receiver: dump
receivers:
  - name: dump
    stdout: {}
EOF
chmod 0644 "$work/config/bad.yaml"
status=0
run "$image" -conf /config/bad.yaml >"$work/badconf" 2>&1 || status=$?
test "$status" -ne 0 || fail 'invalid config unexpectedly succeeded'
grep -F 'validateMetricsNamePrefix failed' "$work/badconf" >/dev/null ||
  fail "invalid-config diagnostic is missing: $(cat "$work/badconf")"

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
  docker run --rm -i --network "$network" -v "$work/kube:/kube:ro" -e KUBECONFIG=/kube/config \
    "$kubectl_image" "$@"
}

i=0
until kubectl get --raw /readyz >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'kube-apiserver did not become ready'
  sleep 2
done

kubectl apply -f - >"$work/apply" 2>&1 <<'EOF' || fail "could not create fixtures: $(cat "$work/apply")"
apiVersion: v1
kind: Namespace
metadata:
  name: smoke
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: smoke-target
  namespace: smoke
  labels:
    app: verity-smoke
data:
  key: value
EOF

# Events in namespace smoke go to a JSON file; reason Noise is dropped first.
cat >"$work/config/config.yaml" <<'EOF'
logLevel: info
logFormat: json
clusterName: verity-smoke
maxEventAgeSeconds: 300
metricsNamePrefix: event_exporter_
route:
  routes:
    - drop:
        - reason: Noise
      match:
        - namespace: smoke
          receiver: file
receivers:
  - name: file
    file:
      path: /out/events.json
EOF
chmod 0644 "$work/config/config.yaml"

docker run -d --name "$exporter" --network "$network" --read-only --tmpfs /tmp --cap-drop=ALL \
  -p 127.0.0.1::2112 -v "$work/kube:/kube:ro" -v "$work/config:/config:ro" -v "$work/out:/out" \
  "$image" -conf /config/config.yaml -kubeconfig /kube/config >/dev/null

port=$(docker port "$exporter" 2112/tcp | awk -F: 'NR == 1 { print $NF }')
[ -n "$port" ] || fail 'metrics port is not published'
i=0
until curl -fsS "http://127.0.0.1:$port/metrics" >"$work/metrics" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'metrics endpoint did not come up'
  sleep 1
done
grep -E "^event_exporter_build_info\\{.*version=\"v$version\".*\\} 1$" "$work/metrics" >/dev/null ||
  fail "build_info does not report v$version: $(grep build_info "$work/metrics")"

# Events created right after start still arrive through the informer's initial list.
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
kubectl apply -f - >"$work/events" 2>&1 <<EOF || fail "could not create events: $(cat "$work/events")"
apiVersion: v1
kind: Event
metadata:
  name: smoke-noise
  namespace: smoke
involvedObject:
  apiVersion: v1
  kind: ConfigMap
  name: smoke-target
  namespace: smoke
reason: Noise
message: dropped by the route
type: Normal
count: 1
firstTimestamp: "$now"
lastTimestamp: "$now"
source:
  component: verity-smoke
---
apiVersion: v1
kind: Event
metadata:
  name: smoke-event
  namespace: smoke
involvedObject:
  apiVersion: v1
  kind: ConfigMap
  name: smoke-target
  namespace: smoke
reason: VeritySmoke
message: exported by the route
type: Warning
count: 1
firstTimestamp: "$now"
lastTimestamp: "$now"
source:
  component: verity-smoke
EOF

i=0
until [ -s "$work/out/events.json" ] && grep -F '"VeritySmoke"' "$work/out/events.json" >/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail "event was not exported: $(cat "$work/out/events.json" 2>/dev/null)"
  sleep 1
done

line=$(grep -F '"VeritySmoke"' "$work/out/events.json" | head -n 1)
printf '%s' "$line" | jq -e --arg ns smoke '
  .reason == "VeritySmoke" and .type == "Warning" and .message == "exported by the route"
  and .clusterName == "verity-smoke" and .metadata.namespace == $ns
  and .involvedObject.kind == "ConfigMap" and .involvedObject.name == "smoke-target"
  and .involvedObject.labels.app == "verity-smoke"' >/dev/null ||
  fail "exported event has unexpected content: $line"

# Negative: the dropped reason never reaches the sink.
if grep -F '"Noise"' "$work/out/events.json" >/dev/null; then
  fail 'dropped event was exported'
fi

curl -fsS "http://127.0.0.1:$port/metrics" >"$work/metrics" || fail 'metrics scrape failed'
sent=$(awk '$1 == "event_exporter_events_sent" { print $2 }' "$work/metrics")
[ -n "$sent" ] && [ "${sent%%.*}" -ge 1 ] 2>/dev/null ||
  fail "events_sent did not count the export: $(grep events_sent "$work/metrics")"

docker inspect -f '{{.State.Running}}' "$exporter" | grep -Fx true >/dev/null ||
  fail 'exporter exited'

printf 'SMOKE PASS\n'
