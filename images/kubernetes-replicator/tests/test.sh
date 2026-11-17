#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# Peers for a real control plane: Verity etcd 3.7, kube-apiserver 1.37 and
# kubectl 1.35, pinned by digest. The replicator only watches and writes
# Namespaces, Secrets, ConfigMaps, Roles, RoleBindings and ServiceAccounts, so
# no scheduler or controller-manager is needed.
etcd_index=ghcr.io/tektum/etcd@sha256:fc322841b20ac374159333e013fb417aa712e776380c53dc34ab8a1958c07fd2
api_index=ghcr.io/tektum/kube-apiserver@sha256:b46742424f608bb186b83390c41cbe7f97df411ae3cf8fc3e4578c096a6b57bd
kubectl_index=ghcr.io/tektum/kubectl@sha256:537780af388652be3a0130aacd6d1cfed24704ab6a820c6c7024602ec7777332

id=$$
label="verity-kubernetes-replicator-test=$id"
network="verity-krepl-$id"
etcd="verity-krepl-etcd-$id"
api="verity-krepl-api-$id"
repl="verity-krepl-$id"
work=$(mktemp -d)
current=''

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  if [ -n "$current" ]; then
    printf -- '--- %s logs\n' "$current" >&2
    docker logs "$current" 2>&1 | tail -n 30 >&2 || true
  fi
  exit 1
}

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'

# OCI contract of the published upstream image (Dockerfile used by
# GoReleaser): USER 65532:65532, ENTRYPOINT ["/replicator"], no CMD, WorkingDir /.
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532:65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/replicator"]' ||
  fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = 'null' ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = / ||
  fail 'unexpected working directory'

# Filesystem: /replicator is the upstream path and resolves to the packaged
# binary, the package database records the recipe version, and the Go build
# info names the upstream module without a misleading VCS pseudo-version
# (the module path has no /v2 suffix, so metadata.yaml declares the identity).
cid=$(docker create --label "$label" "$image") || fail 'cannot create a container'
docker export "$cid" >"$work/rootfs.tar" || fail 'cannot export the image filesystem'
docker rm "$cid" >/dev/null
tar -tvf "$work/rootfs.tar" replicator >"$work/link" 2>&1 || fail 'missing /replicator'
grep -F 'replicator -> /usr/bin/kubernetes-replicator' "$work/link" >/dev/null ||
  fail "unexpected /replicator entry: $(cat "$work/link")"
mkdir "$work/rootfs"
tar -xf "$work/rootfs.tar" -C "$work/rootfs" usr/bin/kubernetes-replicator usr/lib/apk/db/installed ||
  fail 'cannot extract the binary and package database'
awk -v want="$expected_version" '
  $0 == "P:verity-kubernetes-replicator" { found = 1; next }
  found && /^V:/ { split(substr($0, 3), v, "-r"); ok = (v[1] == want); exit }
  END { exit !ok }' "$work/rootfs/usr/lib/apk/db/installed" ||
  fail "package database does not record verity-kubernetes-replicator $expected_version"
tab=$(printf '\t')
bin="$work/rootfs/usr/bin/kubernetes-replicator"
grep -aF "path${tab}github.com/mittwald/kubernetes-replicator" "$bin" >/dev/null ||
  fail 'Go build info does not name the upstream main package'
grep -aF "mod${tab}github.com/mittwald/kubernetes-replicator${tab}(devel)" "$bin" >/dev/null ||
  fail 'Go build info carries an unexpected main module version'
grep -aF 'CGO_ENABLED=0' "$bin" >/dev/null || fail 'binary is not a CGO-disabled build'

run() {
  docker run --rm --label "$label" --read-only --cap-drop=ALL \
    --security-opt=no-new-privileges "$@"
}

# Flags: upstream has no version flag; -h prints the full flag set and exits 0.
run --network none "$image" -h >"$work/help" 2>&1 || fail "-h failed: $(cat "$work/help")"
grep -Fx 'Usage of /replicator:' "$work/help" >/dev/null || fail 'help has no usage line'
for flag in kubeconfig resync-period status-addr log-level log-format allow-all \
  replicate-secrets replicate-configmaps replicate-roles replicate-role-bindings \
  replicate-service-accounts sync-by-content exclude-namespaces \
  push-allowed-source-namespaces; do
  grep -E "^  -$flag( |\$)" "$work/help" >/dev/null || fail "help is missing -$flag"
done

# expect_failure NAME PATTERN ARGS...: the container exits non-zero and logs PATTERN.
expect_failure() {
  name=$1 pattern=$2
  shift 2
  status=0
  run --network none "$@" >"$work/$name" 2>&1 || status=$?
  test "$status" -ne 0 || fail "$name unexpectedly succeeded: $(cat "$work/$name")"
  grep -F -- "$pattern" "$work/$name" >/dev/null ||
    fail "$name is missing '$pattern': $(cat "$work/$name")"
}

expect_failure unknown-flag 'flag provided but not defined: -definitely-invalid-flag' \
  "$image" -definitely-invalid-flag
expect_failure resync 'invalid duration "nope"' "$image" -resync-period nope
# Without a kubeconfig the replicator requires the in-cluster service environment.
expect_failure in-cluster \
  'unable to load in-cluster configuration, KUBERNETES_SERVICE_HOST and KUBERNETES_SERVICE_PORT must be defined' \
  "$image"

mkdir -p "$work/pki" "$work/kube" "$work/bad"
printf 'apiVersion: [' >"$work/bad/malformed"
cat >"$work/bad/offline" <<'EOF'
apiVersion: v1
kind: Config
clusters:
  - name: unreachable
    cluster:
      server: https://127.0.0.1:1
      insecure-skip-tls-verify: true
users:
  - name: nobody
    user:
      token: unused
contexts:
  - name: unreachable
    context:
      cluster: unreachable
      user: nobody
current-context: unreachable
EOF
chmod 0755 "$work/bad" && chmod 0644 "$work/bad/malformed" "$work/bad/offline"
expect_failure missing-kubeconfig 'stat /kube/missing: no such file or directory' \
  -v "$work/bad:/kube:ro" "$image" -kubeconfig /kube/missing
expect_failure malformed-kubeconfig 'error loading config file "/kube/malformed"' \
  -v "$work/bad:/kube:ro" "$image" -kubeconfig /kube/malformed
expect_failure exclude-regex 'invalid value for -exclude-namespaces' \
  -v "$work/bad:/kube:ro" "$image" -kubeconfig /kube/offline -exclude-namespaces '('
expect_failure push-regex 'invalid value for -push-allowed-source-namespaces' \
  -v "$work/bad:/kube:ro" "$image" -kubeconfig /kube/offline -push-allowed-source-namespaces '('

# start NAME ARGS...: run the replicator detached with the status port
# published on loopback and print the host port.
start() {
  name=$1
  shift
  docker run -d --name "$name" --label "$label" --read-only --cap-drop=ALL \
    --security-opt=no-new-privileges -p 127.0.0.1::9102 "$@" >/dev/null ||
    fail "cannot start $name"
  current=$name
  port=$(docker port "$name" 9102/tcp | awk -F: 'NR == 1 { print $NF }')
  [ -n "$port" ] || fail "$name has no published status port"
}

# probe PATH: print "<status> <body>" from the status server.
probe() {
  curl -sS -o "$work/body" -w '%{http_code}' "http://127.0.0.1:$port$1" >"$work/code" 2>/dev/null ||
    printf '000' >"$work/code"
  printf '%s %s' "$(cat "$work/code")" "$(tr -d '\n' <"$work/body" 2>/dev/null || true)"
}

# wait_probe PATH EXPECTED: poll until the status server answers EXPECTED.
wait_probe() {
  i=0
  while :; do
    got=$(probe "$1")
    [ "$got" = "$2" ] && return 0
    i=$((i + 1))
    [ "$i" -lt 60 ] || fail "$1 answered '$got', expected '$2'"
    sleep 1
  done
}

# Offline: with an unreachable API server the controller still serves its
# status endpoints. /healthz is live; /readyz reports every enabled replicator
# as not synced, and the -replicate-* flags change that set.
all_pending='{"notReady":["*secret.Replicator","*configmap.Replicator","*role.Replicator","*rolebinding.Replicator","*serviceaccount.Replicator"]}'
start "$repl-offline" -v "$work/bad:/kube:ro" "$image" -kubeconfig /kube/offline
wait_probe /healthz '200 '
wait_probe /readyz "503 $all_pending"
test "$(probe /metrics)" = '404 404 page not found' || fail 'unexpected /metrics response'
docker logs "$repl-offline" 2>&1 | grep -F 'starting liveness monitor at :9102' >/dev/null ||
  fail 'missing liveness monitor log line'
# SIGTERM stops the controller promptly.
before=$(date +%s)
docker stop -t 20 "$repl-offline" >/dev/null || fail 'docker stop failed'
elapsed=$(($(date +%s) - before))
[ "$elapsed" -lt 15 ] || fail "SIGTERM took ${elapsed}s"
docker rm "$repl-offline" >/dev/null

start "$repl-subset" -v "$work/bad:/kube:ro" "$image" -kubeconfig /kube/offline \
  -replicate-roles=false -replicate-role-bindings=false -replicate-service-accounts=false \
  -log-format json -log-level debug
wait_probe /readyz '503 {"notReady":["*secret.Replicator","*configmap.Replicator"]}'
docker logs "$repl-subset" 2>&1 | grep -F '"msg":"starting liveness monitor at :9102"' >/dev/null ||
  fail 'JSON log format was not applied'
docker rm -f "$repl-subset" >/dev/null

start "$repl-none" -v "$work/bad:/kube:ro" "$image" -kubeconfig /kube/offline \
  -replicate-secrets=false -replicate-configmaps=false -replicate-roles=false \
  -replicate-role-bindings=false -replicate-service-accounts=false
wait_probe /readyz '200 {"notReady":[]}'
docker rm -f "$repl-none" >/dev/null
current=''

# Control plane: etcd and kube-apiserver with static tokens for an admin and
# for the replicator, which is bound to the upstream deploy/rbac.yaml ClusterRole.
openssl genrsa -out "$work/pki/sa.key" 2048 2>/dev/null || fail 'could not generate the service account key'
admin_token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
repl_token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
{
  printf '%s,verity-admin,verity-admin,system:masters\n' "$admin_token"
  printf '%s,verity-replicator,verity-replicator\n' "$repl_token"
} >"$work/pki/tokens.csv"
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
kubeconfig "$repl_token" >"$work/kube/replicator"
kubeconfig "wrong-$repl_token" >"$work/kube/wrong"
chmod 0755 "$work/pki" "$work/kube"
chmod 0644 "$work/pki/sa.key" "$work/pki/tokens.csv" "$work/kube/admin" \
  "$work/kube/replicator" "$work/kube/wrong"

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
current=$api

kubectl() {
  docker run --rm -i --label "$label" --network "$network" -v "$work/kube:/kube:ro" \
    -e KUBECONFIG=/kube/admin "$kubectl_image" "$@"
}

i=0
until kubectl get --raw /readyz >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'kube-apiserver did not become ready'
  sleep 2
done

# Fixture present before the replicator starts (initial list path):
# - src/app-secret allows pulls into dst; dst/app-copy pulls it.
# - src/private allows nothing; dst/private-copy tries to pull it anyway.
# - src/shared pushes into dst (which accepts pushes from src) and into
#   closed (which does not, so the v2.12.5 push policy must refuse it).
# - dst/foreign is an unrelated object that src/foreign must not overwrite.
kubectl apply -f - >/dev/null <<'EOF' || fail 'cannot apply the fixture'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: replicator-kubernetes-replicator
rules:
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["get", "watch", "list"]
  - apiGroups: [""]
    resources: ["secrets", "configmaps", "serviceaccounts"]
    verbs: ["get", "watch", "list", "create", "update", "patch", "delete"]
  - apiGroups: ["rbac.authorization.k8s.io"]
    resources: ["roles", "rolebindings"]
    verbs: ["get", "watch", "list", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: replicator-kubernetes-replicator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: replicator-kubernetes-replicator
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: verity-replicator
---
apiVersion: v1
kind: Namespace
metadata:
  name: src
---
apiVersion: v1
kind: Namespace
metadata:
  name: dst
  annotations:
    replicator.v1.mittwald.de/allow-push-from: src
---
apiVersion: v1
kind: Namespace
metadata:
  name: closed
---
apiVersion: v1
kind: Secret
metadata:
  name: app-secret
  namespace: src
  annotations:
    replicator.v1.mittwald.de/replication-allowed: "true"
    replicator.v1.mittwald.de/replication-allowed-namespaces: dst
stringData:
  password: s3cret-one
---
apiVersion: v1
kind: Secret
metadata:
  name: app-copy
  namespace: dst
  annotations:
    replicator.v1.mittwald.de/replicate-from: src/app-secret
---
apiVersion: v1
kind: Secret
metadata:
  name: private
  namespace: src
stringData:
  password: never-copied
---
apiVersion: v1
kind: Secret
metadata:
  name: private-copy
  namespace: dst
  annotations:
    replicator.v1.mittwald.de/replicate-from: src/private
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: shared
  namespace: src
  annotations:
    replicator.v1.mittwald.de/replicate-to: dst,closed
data:
  greeting: hello
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: foreign
  namespace: dst
data:
  owner: someone-else
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: foreign
  namespace: src
  annotations:
    replicator.v1.mittwald.de/replicate-to: dst
data:
  owner: replicator
EOF

# Negative: a wrong token is rejected by the API server, so the replicator
# never becomes ready and logs the authentication failure.
start "$repl-unauth" --network "$network" -v "$work/kube:/kube:ro" "$image" -kubeconfig /kube/wrong
wait_probe /healthz '200 '
i=0
until docker logs "$repl-unauth" 2>&1 | grep -F 'Unauthorized' >/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'unauthenticated replicator did not log Unauthorized'
  sleep 1
done
wait_probe /readyz "503 $all_pending"
docker rm -f "$repl-unauth" >/dev/null

start "$repl" --network "$network" -v "$work/kube:/kube:ro" "$image" -kubeconfig /kube/replicator
# Readiness against a real API server: every informer has synced.
wait_probe /readyz '200 {"notReady":[]}'

# wait_get EXPECTED KUBECTL-ARGS...: poll a kubectl jsonpath query.
wait_get() {
  want=$1
  shift
  i=0
  while :; do
    got=$(kubectl get "$@" 2>/dev/null || true)
    [ "$got" = "$want" ] && return 0
    i=$((i + 1))
    [ "$i" -lt 60 ] || fail "kubectl get $* returned '$got', expected '$want'"
    sleep 1
  done
}
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

# Pull replication copies the allowed Secret.
wait_get "$(b64 s3cret-one)" secret -n dst app-copy -o 'jsonpath={.data.password}'
# Push replication into the consenting namespace, marked with its source.
wait_get hello configmap -n dst shared -o 'jsonpath={.data.greeting}'
wait_get src/shared configmap -n dst shared \
  -o 'jsonpath={.metadata.annotations.replicator\.v1\.mittwald\.de/replicated-from-source}'

# Watch path: source updates propagate to both kinds of copies.
kubectl patch secret -n src app-secret --type merge -p '{"stringData":{"password":"s3cret-two"}}' \
  >/dev/null || fail 'cannot update the source Secret'
kubectl patch configmap -n src shared --type merge -p '{"data":{"greeting":"updated"}}' \
  >/dev/null || fail 'cannot update the source ConfigMap'
wait_get "$(b64 s3cret-two)" secret -n dst app-copy -o 'jsonpath={.data.password}'
wait_get updated configmap -n dst shared -o 'jsonpath={.data.greeting}'

# A namespace created later receives pushes once it consents.
kubectl create namespace late >/dev/null || fail 'cannot create namespace late'
kubectl patch configmap -n src shared --type merge \
  -p '{"metadata":{"annotations":{"replicator.v1.mittwald.de/replicate-to":"dst,closed,late"}}}' \
  >/dev/null || fail 'cannot extend the push targets'
kubectl annotate namespace late replicator.v1.mittwald.de/allow-push-from=src >/dev/null ||
  fail 'cannot annotate namespace late'
wait_get updated configmap -n late shared -o 'jsonpath={.data.greeting}'

# Negatives, checked after the positive cases above converged.
sleep 3
if kubectl get configmap -n closed shared >/dev/null 2>&1; then
  fail 'pushed into a namespace that does not accept pushes from src'
fi
test -z "$(kubectl get secret -n dst private-copy -o 'jsonpath={.data}')" ||
  fail 'pulled a Secret whose source does not allow replication'
test "$(kubectl get configmap -n dst foreign -o 'jsonpath={.data.owner}')" = someone-else ||
  fail 'push replication overwrote an object it did not create'
docker logs "$repl" 2>&1 |
  grep -F 'not replicating src/shared into 1 matching namespace(s): namespace excluded or pushing from namespace src not permitted' \
    >/dev/null || fail 'missing push policy refusal log for namespace closed'

# Deleting a push source removes its copies.
kubectl delete configmap -n src shared >/dev/null || fail 'cannot delete the push source'
i=0
while kubectl get configmap -n dst shared >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'pushed copy survived deletion of its source'
  sleep 1
done

docker stop -t 20 "$repl" >/dev/null || fail 'docker stop failed'

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$expected_version"
