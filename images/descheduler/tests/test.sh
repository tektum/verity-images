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
network="verity-desched-$id"
etcd="verity-desched-etcd-$id"
api="verity-desched-api-$id"
dry="verity-desched-dry-$id"
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  docker logs "$api" 2>&1 | tail -n 20 >&2 || true
  exit 1
}

cleanup() {
  docker rm -f "$dry" "$api" "$etcd" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'

# OCI contract: upstream runs as UID 1000 with --help as the default argument.
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 1000 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/descheduler"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["--help"]' ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/descheduler ||
  fail 'unexpected working directory'

run() {
  docker run --rm --read-only --cap-drop=ALL --security-opt=no-new-privileges "$@"
}

# Default command prints the help, like the upstream image.
run --network none "$image" >"$work/help" 2>&1 || fail "default --help failed: $(cat "$work/help")"
for flag in --policy-config-file --descheduling-interval --dry-run --kubeconfig --leader-elect; do
  grep -F -e "$flag" "$work/help" >/dev/null || fail "help is missing $flag"
done

# Version stamps from the upstream Makefile ldflags.
run --network none "$image" version >"$work/version" 2>&1 || fail "version failed: $(cat "$work/version")"
minor=${expected_version#*.}
grep -E "^Descheduler version \{Major:0 Minor:$minor GitVersion:v[0-9]{8}-v$expected_version GitBranch: GitSha1:[0-9a-f]{40} BuildDate:[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}\+0000 GoVersion:go1\.[0-9.]+ Compiler:gc Platform:linux/(amd64|arm64)\}$" \
  "$work/version" >/dev/null || fail "unexpected version output: $(cat "$work/version")"

# The upstream image and Helm chart invoke /bin/descheduler.
run --network none --entrypoint /bin/descheduler "$image" version >/dev/null 2>&1 ||
  fail 'compatibility path /bin/descheduler does not run'

# Unknown flag.
status=0
run --network none "$image" --definitely-invalid >"$work/invalid" 2>&1 || status=$?
test "$status" -ne 0 || fail 'unknown flag unexpectedly succeeded'
grep -Fx 'Error: unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail "unknown flag diagnostic is missing: $(cat "$work/invalid")"

# Control plane: etcd and kube-apiserver with a static admin token.
mkdir -p "$work/pki" "$work/kube" "$work/policy"
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

# PodLifeTime evicts pods older than one second, but only in namespace
# desched-target and only with label app=victim.
cat >"$work/policy/policy.yaml" <<'EOF'
apiVersion: descheduler/v1alpha2
kind: DeschedulerPolicy
profiles:
  - name: smoke
    pluginConfig:
      - name: DefaultEvictor
      - name: PodLifeTime
        args:
          maxPodLifeTimeSeconds: 1
          namespaces:
            include: [desched-target]
          labelSelector:
            matchLabels:
              app: victim
    plugins:
      deschedule:
        enabled: [PodLifeTime]
EOF
# Semantically invalid: Include and Exclude namespaces together.
cat >"$work/policy/conflict.yaml" <<'EOF'
apiVersion: descheduler/v1alpha2
kind: DeschedulerPolicy
profiles:
  - name: broken
    pluginConfig:
      - name: PodLifeTime
        args:
          maxPodLifeTimeSeconds: 1
          namespaces:
            include: [a]
            exclude: [b]
    plugins:
      deschedule:
        enabled: [PodLifeTime]
EOF
# Not a decodable policy.
cat >"$work/policy/garbage.yaml" <<'EOF'
apiVersion: descheduler/v1alpha2
kind: DeschedulerPolicy
profiles: 5
EOF
chmod 0644 "$work/pki/sa.key" "$work/pki/tokens.csv" "$work/kube/config" "$work/policy/"*.yaml

# pull_child INDEX: pull the pinned index by its per-platform child digest,
# verifying the index bytes against the pin first so the pin stays authoritative.
# The publish job runs this test per architecture against one daemon, so an
# index digest must never be passed straight to docker run.
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

# The descheduler runs out of cluster with the kubeconfig and the policy
# mounted read-only on a read-only root filesystem.
descheduler() {
  run --network "$network" -v "$work/kube:/kube:ro" -v "$work/policy:/policy:ro" "$image" \
    --kubeconfig=/kube/config --descheduling-interval=0 --v=1 "$@"
}

# Invalid policies fail before any descheduling with the exact upstream
# diagnostic as the final klog line: "command failed" err="<message>".
rejects() { # policy-file expected-message
  status=0
  descheduler --policy-config-file="$1" >"$work/rejected" 2>&1 || status=$?
  test "$status" -ne 0 || fail "policy $1 unexpectedly succeeded"
  want="\"command failed\" err=\"$2\"" awk '
    substr($0, length($0) - length(ENVIRON["want"]) + 1) == ENVIRON["want"] { found = 1 }
    END { exit !found }' "$work/rejected" ||
    fail "policy $1 diagnostic is missing: $(cat "$work/rejected")"
}
rejects /policy/conflict.yaml 'in profile broken: only one of Include/Exclude namespaces can be set'
rejects /policy/garbage.yaml \
  "failed decoding descheduler's policy config \\\"/policy/garbage.yaml\\\": json: cannot unmarshal number into Go struct field DeschedulerPolicy.profiles of type []v1alpha2.DeschedulerProfile"
rejects /policy/missing.yaml \
  'failed to read policy config file \"/policy/missing.yaml\": open /policy/missing.yaml: no such file or directory'

i=0
until kubectl get --raw /readyz >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'kube-apiserver did not become ready'
  sleep 2
done

# No kube-controller-manager runs, so the default service accounts are created
# here and the owning ReplicaSet is referenced by a fixed UID. DefaultEvictor
# never evicts bare pods, so every candidate needs an ownerReference.
pod() { # name namespace app owned
  owner=''
  if [ "$4" = owned ]; then
    owner="
  ownerReferences:
    - apiVersion: apps/v1
      kind: ReplicaSet
      name: smoke
      uid: 6f1e2a3b-0000-4000-8000-000000000001
      controller: true"
  fi
  cat <<EOF
---
apiVersion: v1
kind: Pod
metadata:
  name: $1
  namespace: $2
  labels:
    app: $3$owner
spec:
  nodeName: node1
  automountServiceAccountToken: false
  containers:
    - name: main
      image: registry.k8s.io/pause:3.10
EOF
}

{
  cat <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: desched-target
---
apiVersion: v1
kind: Namespace
metadata:
  name: desched-other
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
  namespace: desched-target
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
  namespace: desched-other
---
apiVersion: v1
kind: Node
metadata:
  name: node1
  labels:
    kubernetes.io/hostname: node1
---
apiVersion: v1
kind: Node
metadata:
  name: node2
  labels:
    kubernetes.io/hostname: node2
EOF
  pod victim desched-target victim owned
  pod bystander desched-target bystander owned
  pod bare desched-target victim bare
  pod elsewhere desched-other victim owned
} | kubectl apply -f - >"$work/apply" 2>&1 || fail "could not create fixtures: $(cat "$work/apply")"

# The descheduler only considers Ready nodes and skips a cycle with fewer than
# two of them; no kubelet reports their status here.
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for node in node1 node2; do
  kubectl patch node "$node" --subresource=status --type=merge -p "{\"status\":{
    \"capacity\":{\"cpu\":\"4\",\"memory\":\"8Gi\",\"pods\":\"110\"},
    \"allocatable\":{\"cpu\":\"4\",\"memory\":\"8Gi\",\"pods\":\"110\"},
    \"conditions\":[{\"type\":\"Ready\",\"status\":\"True\",\"reason\":\"KubeletReady\",
      \"message\":\"smoke\",\"lastHeartbeatTime\":\"$now\",\"lastTransitionTime\":\"$now\"}]}}" \
    >"$work/patch" 2>&1 || fail "could not mark $node Ready: $(cat "$work/patch")"
  test "$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True ||
    fail "$node is not Ready"
done

# Every pod is older than maxPodLifeTimeSeconds.
sleep 3

terminating() { # namespace name; true when the pod is gone or being deleted
  out=$(kubectl get pod -n "$1" "$2" --ignore-not-found -o jsonpath='{.metadata.name}/{.metadata.deletionTimestamp}' 2>&1) ||
    fail "could not read pod $1/$2: $out"
  case "$out" in
    '' | "$2"/?*) return 0 ;;
    "$2"/) return 1 ;;
    *) fail "unexpected pod state for $1/$2: $out" ;;
  esac
}

# A one-shot dry run evicts nothing. Upstream mirrors the cluster into the
# dry-run sandbox asynchronously, so its first cycle may still see no nodes;
# selection is therefore asserted from a looping dry run below.
descheduler --policy-config-file=/policy/policy.yaml --dry-run >"$work/dry" 2>&1 ||
  fail "one-shot dry run failed: $(cat "$work/dry")"
grep -F '"Number of evictions/requests"' "$work/dry" >/dev/null ||
  fail "one-shot dry run did not run a cycle: $(cat "$work/dry")"
if grep -F '"Evicted pod"' "$work/dry" >/dev/null; then
  fail "one-shot dry run evicted a pod: $(cat "$work/dry")"
fi

# A looping dry run (the long-running mode, serving on a read-only root)
# selects exactly the matching owned pod, then stops cleanly on SIGTERM.
docker run -d --name "$dry" --read-only --cap-drop=ALL --security-opt=no-new-privileges \
  --network "$network" -v "$work/kube:/kube:ro" -v "$work/policy:/policy:ro" "$image" \
  --kubeconfig=/kube/config --policy-config-file=/policy/policy.yaml --dry-run \
  --descheduling-interval=2s --v=1 >/dev/null || fail 'could not start the looping dry run'
i=0
until docker logs "$dry" 2>&1 | grep -F '"Evicted pod in dry run mode" pod="desched-target/victim" reason="" strategy="PodLifeTime" node="node1" profile="smoke"' >/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail "dry run did not select the victim: $(docker logs "$dry" 2>&1 | tail -n 20)"
  sleep 1
done
docker stop -t 20 "$dry" >/dev/null || fail 'could not stop the looping dry run'
test "$(docker inspect --format '{{.State.ExitCode}}' "$dry")" = 0 ||
  fail "looping dry run did not exit cleanly: $(docker logs "$dry" 2>&1 | tail -n 20)"
docker logs "$dry" >"$work/dry-loop" 2>&1
if grep -F 'Evicted pod' "$work/dry-loop" | grep -Fv 'pod="desched-target/victim"' >/dev/null; then
  fail "dry run selected a non-matching pod: $(cat "$work/dry-loop")"
fi
if grep -F '"Evicted pod"' "$work/dry-loop" >/dev/null; then
  fail "looping dry run evicted a pod: $(cat "$work/dry-loop")"
fi
for p in desched-target/victim desched-target/bystander desched-target/bare desched-other/elsewhere; do
  if terminating "${p%/*}" "${p#*/}"; then fail "dry run evicted $p"; fi
done

# Real one-shot run evicts only the matching owned pod.
descheduler --policy-config-file=/policy/policy.yaml >"$work/real" 2>&1 ||
  fail "descheduler run failed: $(cat "$work/real")"
grep -F '"Evicted pod" pod="desched-target/victim" reason="" strategy="PodLifeTime" node="node1" profile="smoke"' \
  "$work/real" >/dev/null || fail "eviction log line is missing: $(cat "$work/real")"
if grep -F 'Evicted pod' "$work/real" | grep -Fv 'pod="desched-target/victim"' >/dev/null; then
  fail "a non-matching pod was evicted: $(cat "$work/real")"
fi
grep -F '"Number of evictions/requests" totalEvicted=1 evictionRequests=0' "$work/real" >/dev/null ||
  fail "eviction total is not exactly one: $(cat "$work/real")"
terminating desched-target victim || fail 'victim was not evicted'
for p in desched-target/bystander desched-target/bare desched-other/elsewhere; do
  if terminating "${p%/*}" "${p#*/}"; then fail "$p was evicted"; fi
done
# Upstream records a Descheduled event asynchronously and a one-shot run exits
# before the event sink flushes, so the log line above is the eviction record.

printf 'descheduler %s smoke test passed\n' "$expected_version"
