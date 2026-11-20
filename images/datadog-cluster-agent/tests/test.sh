#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
recipe="$here/../melange.yaml"
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' "$recipe")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
source_commit=$(sed -n 's/^[[:space:]]*source-commit: \([0-9a-f]\{40\}\)$/\1/p' "$recipe")
[ -n "$source_commit" ] || { printf 'source commit not found\n' >&2; exit 1; }
short_commit=$(printf '%s' "$source_commit" | cut -c1-7)

# Peers for a real control plane: Verity etcd 3.7, kube-apiserver 1.37 and
# kubectl 1.35, pinned by digest.
etcd_index=ghcr.io/tektum/etcd@sha256:fc322841b20ac374159333e013fb417aa712e776380c53dc34ab8a1958c07fd2
api_index=ghcr.io/tektum/kube-apiserver@sha256:b46742424f608bb186b83390c41cbe7f97df411ae3cf8fc3e4578c096a6b57bd
kubectl_index=ghcr.io/tektum/kubectl@sha256:537780af388652be3a0130aacd6d1cfed24704ab6a820c6c7024602ec7777332
# Placeholder key: the cluster agent only needs one to be configured. The
# test network is internal, so nothing can reach Datadog.
fake_api_key=00000000000000000000000000000000

id=$$
network="verity-dca-$id"
etcd="verity-dca-etcd-$id"
api="verity-dca-api-$id"
dca="verity-dca-$id"
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  for c in "$dca" "$api"; do
    if docker inspect "$c" >/dev/null 2>&1; then
      printf -- '--- %s logs\n' "$c" >&2
      docker logs --tail 40 "$c" >&2 2>&1 || true
    fi
  done
  exit 1
}

cleanup() {
  docker rm -f "$dca" "$api" "$etcd" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

inspect() {
  docker image inspect "$image" --format "$1"
}

# OCI contract: the upstream command, without its root bash entrypoint.
[ "$(inspect '{{.Config.User}}')" = 65532 ] ||
  fail "image user is $(inspect '{{.Config.User}}'), want 65532"
[ "$(inspect '{{json .Config.Entrypoint}}')" = null ] ||
  fail "unexpected entrypoint: $(inspect '{{json .Config.Entrypoint}}')"
[ "$(inspect '{{json .Config.Cmd}}')" = '["datadog-cluster-agent","start"]' ] ||
  fail "unexpected cmd: $(inspect '{{json .Config.Cmd}}')"
inspect '{{range .Config.Env}}{{println .}}{{end}}' >"$work/env"
grep -Fx 'PATH=/opt/datadog-agent/bin:/usr/sbin:/usr/bin:/sbin:/bin' "$work/env" >/dev/null ||
  fail "unexpected PATH: $(grep '^PATH=' "$work/env")"
grep -Fx 'DOCKER_DD_AGENT=true' "$work/env" >/dev/null || fail 'DOCKER_DD_AGENT is not set'

run() {
  docker run --rm --cap-drop=ALL --security-opt=no-new-privileges "$@"
}

# Version stamps from get_version_ldflags, through both upstream names.
for cmd in datadog-cluster-agent agent /opt/datadog-agent/bin/datadog-cluster-agent; do
  out=$(run --network none --entrypoint "$cmd" "$image" version 2>&1) ||
    fail "$cmd version failed: $out"
  printf '%s\n' "$out" | grep -F "Cluster Agent $expected_version - Commit: $short_commit - Serialization version: v" >/dev/null ||
    fail "unexpected $cmd version output: $out"
done

# Without an API key the cluster agent refuses to start. Offline it cannot
# resolve a hostname, which it checks first, so pin one.
status=0
run --network none -e DD_HOSTNAME=verity-smoke "$image" >"$work/nokey" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail 'start without DD_API_KEY unexpectedly succeeded'
grep -Fx 'Error: no API key configured, exiting' "$work/nokey" >/dev/null ||
  fail "missing API key diagnostic: $(tail -5 "$work/nokey")"

# Control plane: etcd and kube-apiserver with a static admin token, on an
# internal network with no route off the host. Without a default route the
# API server needs an explicit advertise address; TEST-NET-1 is never routed.
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
# verifying the index bytes against the pin first so the pin stays
# authoritative. The publish job runs this test per architecture against one
# daemon, so an index digest must never be passed straight to docker run.
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

docker network create --internal "$network" >/dev/null
docker run -d --name "$etcd" --network "$network" --tmpfs /var/lib/etcd:uid=65532,gid=65532 \
  "$etcd_image" --data-dir=/var/lib/etcd/data \
  --listen-client-urls=http://0.0.0.0:2379 --advertise-client-urls="http://$etcd:2379" >/dev/null
docker run -d --name "$api" --network "$network" --tmpfs /tmp:uid=65532,gid=65532 \
  -v "$work/pki:/pki:ro" "$api_image" \
  --etcd-servers="http://$etcd:2379" --secure-port=6443 --cert-dir=/tmp \
  --token-auth-file=/pki/tokens.csv --authorization-mode=RBAC \
  --service-account-issuer=https://kubernetes.default.svc \
  --service-account-key-file=/pki/sa.key --service-account-signing-key-file=/pki/sa.key \
  --service-cluster-ip-range=10.96.0.0/16 --advertise-address=192.0.2.1 >/dev/null

kubectl() {
  docker run --rm -i --network "$network" -v "$work/kube:/kube:ro" -e KUBECONFIG=/kube/config \
    "$kubectl_image" "$@"
}

i=0
until kubectl get --raw /readyz >/dev/null 2>&1; do
  [ "$(docker inspect "$api" --format '{{.State.Running}}')" = true ] ||
    fail 'kube-apiserver exited'
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'kube-apiserver did not become ready'
  sleep 2
done

# The cluster agent runs out of cluster against the kubeconfig, on a
# read-only root filesystem with the upstream writable volumes as tmpfs, and
# must win leader election and report itself healthy.
pod_name=verity-dca-smoke
docker run -d --name "$dca" --network "$network" --read-only \
  --cap-drop=ALL --security-opt=no-new-privileges \
  --tmpfs /opt/datadog-agent/run:uid=65532,gid=65532 \
  --tmpfs /var/log/datadog:uid=65532,gid=65532 \
  --tmpfs /tmp:uid=65532,gid=65532 \
  -v "$work/kube:/kube:ro" \
  -e DD_API_KEY="$fake_api_key" \
  -e DD_KUBERNETES_KUBECONFIG_PATH=/kube/config \
  -e DD_POD_NAME="$pod_name" \
  -e DD_KUBE_RESOURCES_NAMESPACE=default \
  -e DD_CLUSTER_NAME=verity-smoke \
  -e DD_HOSTNAME=verity-smoke \
  -e DD_LEADER_ELECTION=true \
  -e DD_LOG_TO_CONSOLE=true \
  "$image" >/dev/null || fail 'cannot start the cluster agent'

i=0
until docker exec "$dca" datadog-cluster-agent health >"$work/health" 2>&1; do
  [ "$(docker inspect "$dca" --format '{{.State.Running}}')" = true ] ||
    fail "cluster agent exited $(docker inspect "$dca" --format '{{.State.ExitCode}}')"
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail "cluster agent never became healthy: $(cat "$work/health")"
  sleep 2
done
grep -F 'Agent health: PASS' "$work/health" >/dev/null ||
  fail "unexpected health output: $(cat "$work/health")"

# Leader election writes its lease to the API server with this pod as holder.
# The cluster agent starts campaigning only after its other start-up work,
# which can take minutes on a loaded runner.
deadline=$(($(date +%s) + 300))
until holder=$(kubectl -n default get lease datadog-leader-election \
  -o jsonpath='{.spec.holderIdentity}' 2>&1) && [ "$holder" = "$pod_name" ]; do
  [ "$(date +%s)" -lt "$deadline" ] ||
    fail "lease datadog-leader-election is not held by $pod_name: $holder"
  sleep 2
done

# The authenticated IPC API on the cmd port serves the status page.
docker exec "$dca" datadog-cluster-agent status >"$work/status" 2>&1 ||
  fail "status failed: $(tail -20 "$work/status")"
grep -F "Agent (v$expected_version)" "$work/status" >/dev/null ||
  fail "status does not report v$expected_version: $(head -20 "$work/status")"
grep -F "Leader Name is: $pod_name" "$work/status" >/dev/null ||
  fail "status does not name $pod_name as leader: $(grep -i -A6 'leader election' "$work/status")"

# The running agent reflects the environment configuration.
docker exec "$dca" datadog-cluster-agent config >"$work/config" 2>&1 ||
  fail "config failed: $(tail -5 "$work/config")"
grep -Fx 'cluster_name: verity-smoke' "$work/config" >/dev/null ||
  fail 'runtime config does not reflect DD_CLUSTER_NAME'

docker stop -t 30 "$dca" >/dev/null
[ "$(docker inspect "$dca" --format '{{.State.ExitCode}}')" = 0 ] ||
  fail "cluster agent exited $(docker inspect "$dca" --format '{{.State.ExitCode}}') on SIGTERM"

printf 'datadog-cluster-agent smoke test passed\n'
