#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
config="$here/../apko.yaml"
version=$(sed -n 's/^    - kapp=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
work=$(mktemp -d)

# Peers for a real control plane: Verity etcd 3.7, kube-apiserver 1.37 and
# kubectl 1.35, pinned by index digest.
etcd_index=ghcr.io/tektum/etcd@sha256:fc322841b20ac374159333e013fb417aa712e776380c53dc34ab8a1958c07fd2
api_index=ghcr.io/tektum/kube-apiserver@sha256:b46742424f608bb186b83390c41cbe7f97df411ae3cf8fc3e4578c096a6b57bd
kubectl_index=ghcr.io/tektum/kubectl@sha256:537780af388652be3a0130aacd6d1cfed24704ab6a820c6c7024602ec7777332
network="verity-kapp-$$"
etcd="verity-kapp-etcd-$$"
api="verity-kapp-api-$$"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  if docker container inspect "$api" >/dev/null 2>&1; then
    printf -- '--- %s\n' "$api" >&2
    docker logs "$api" 2>&1 | tail -n 30 >&2 || true
  fi
  exit 1
}

cleanup() {
  docker rm -f "$api" "$etcd" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail 'could not read the pinned kapp version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/kapp"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

# Every check runs offline on a read-only root with no capabilities. The input
# tree is mounted read-only at the image working directory.
run() {
  docker run --rm --network none --read-only --cap-drop=ALL \
    -v "$work/in:/work:ro" "$image" "$@"
}

# Run a command that must fail; its combined output lands in $work/$1.
expect_fail() {
  name=$1
  shift
  rc=0
  run "$@" >"$work/$name" 2>&1 || rc=$?
  test "$rc" -ne 0 || fail "$name: command unexpectedly succeeded: $(cat "$work/$name")"
}

expect_line() {
  file=$1
  line=$2
  grep -F -- "$line" "$work/$file" >/dev/null ||
    fail "$file lacks '$line': $(cat "$work/$file")"
}

mkdir -p "$work/in/tree/sub"

# Desired state: an updated ConfigMap, a scaled Deployment, and a new Secret.
cat >"$work/in/app.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: web
  namespace: demo
  labels:
    tier: frontend
data:
  greeting: goodbye
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: demo
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: web
        image: nginx
---
apiVersion: v1
kind: Secret
metadata:
  name: creds
  namespace: demo
stringData:
  password: hunter2
EOF
# Existing state: the old ConfigMap and Deployment plus a Service that the
# desired state drops.
cat >"$work/in/live.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: web
  namespace: demo
  labels:
    tier: frontend
data:
  greeting: hello
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: web
        image: nginx
---
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: demo
spec:
  selector:
    app: web
  ports:
  - port: 80
EOF
cp "$work/in/app.yaml" "$work/in/tree/app.yaml"
printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: demo\n' \
  >"$work/in/tree/sub/ns.yaml"
printf 'Not a manifest, ignored by directory input.\n' >"$work/in/tree/README.md"
printf 'kind: [\n' >"$work/in/broken.yaml"
cat >"$work/in/kubeconfig" <<'EOF'
apiVersion: v1
kind: Config
clusters:
- name: dead
  cluster:
    server: https://127.0.0.1:1
contexts:
- name: dead
  context:
    cluster: dead
    user: smoke
    namespace: demo
current-context: dead
users:
- name: smoke
  user:
    token: not-a-real-token
EOF
chmod -R a+rX "$work/in"

# Version reported by the binary matches the pinned package.
out=$(run version) || fail "kapp version failed: $out"
test "$out" = "kapp version v$version" || fail "unexpected version output: $out"
out=$(run --version) || fail "kapp --version failed: $out"
case $out in
  *"$version"*) ;;
  *) fail "--version does not report $version: $out" ;;
esac

# tools inspect parses every document of a local multi-document file.
run tools inspect -f app.yaml --json >"$work/inspect.json" ||
  fail "tools inspect --json failed: $(cat "$work/inspect.json")"
rows=$(jq -r '.Tables[0].Rows[] | [.namespace, .kind, .name] | join("/")' \
  "$work/inspect.json" | sort | paste -sd, -)
test "$rows" = 'demo/ConfigMap/web,demo/Deployment/web,demo/Secret/creds' ||
  fail "unexpected inspected resources: $rows"
test "$(jq -r '.Lines | join(",")' "$work/inspect.json")" = Succeeded ||
  fail "inspect did not report success: $(cat "$work/inspect.json")"

run tools inspect -f app.yaml --tty --color=false >"$work/inspect.txt" 2>&1 ||
  fail "tools inspect table failed: $(cat "$work/inspect.txt")"
expect_line inspect.txt "Resources in file 'app.yaml'"
expect_line inspect.txt '3 resources'

# --raw re-emits the parsed objects as YAML.
run tools inspect -f app.yaml --raw >"$work/raw.yaml" 2>&1 ||
  fail "tools inspect --raw failed: $(cat "$work/raw.yaml")"
expect_line raw.yaml '  greeting: goodbye'
expect_line raw.yaml '  replicas: 3'
test "$(grep -c '^kind: ' "$work/raw.yaml")" -eq 3 ||
  fail "--raw did not emit three objects: $(cat "$work/raw.yaml")"

# Standard input and recursive directory input; non-YAML files are skipped.
docker run --rm -i --network none --read-only --cap-drop=ALL "$image" \
  tools inspect -f - --tty --color=false <"$work/in/app.yaml" >"$work/stdin.txt" 2>&1 ||
  fail "tools inspect from stdin failed: $(cat "$work/stdin.txt")"
expect_line stdin.txt 'Resources in stdin'
expect_line stdin.txt '3 resources'

run tools inspect -f tree --tty --color=false >"$work/tree.txt" 2>&1 ||
  fail "tools inspect of a directory failed: $(cat "$work/tree.txt")"
expect_line tree.txt "Resources in file 'app.yaml'"
expect_line tree.txt "Resources in file 'sub/ns.yaml'"
expect_line tree.txt '1 resources'
if grep -F README "$work/tree.txt" >/dev/null; then
  fail "directory input read a non-YAML file: $(cat "$work/tree.txt")"
fi

# tools diff computes create, update, and delete operations between two local
# file sets without a cluster.
run tools diff -f app.yaml --file2 live.yaml --json >"$work/diff.json" ||
  fail "tools diff --json failed: $(cat "$work/diff.json")"
ops=$(jq -r '.Tables[0].Rows[] | [.kind, .name, .op] | join("/")' \
  "$work/diff.json" | sort | paste -sd, -)
test "$ops" = 'ConfigMap/web/update,Deployment/web/update,Secret/creds/create,Service/web/delete' ||
  fail "unexpected diff operations: $ops"
summary=$(jq -r '.Tables[0].Notes[0]' "$work/diff.json")
test "$summary" = 'Op:      1 create, 1 delete, 2 update, 0 noop, 0 exists' ||
  fail "unexpected diff summary: $summary"

run tools diff -f app.yaml --file2 live.yaml -c --summary=false --tty --color=false \
  >"$work/changes.txt" 2>&1 || fail "tools diff -c failed: $(cat "$work/changes.txt")"
expect_line changes.txt '@@ update configmap/web (v1) namespace: demo @@'
expect_line changes.txt '@@ create secret/creds (v1) namespace: demo @@'
expect_line changes.txt '@@ delete service/web (v1) namespace: demo @@'
expect_line changes.txt '-   greeting: hello'
expect_line changes.txt '+   greeting: goodbye'
expect_line changes.txt '-   replicas: 1'
expect_line changes.txt '+   replicas: 3'

run tools diff -f app.yaml --file2 live.yaml --changes-yaml --summary=false \
  --color=false >"$work/changes.yaml" 2>&1 ||
  fail "tools diff --changes-yaml failed: $(cat "$work/changes.yaml")"
expect_line changes.yaml '# update: deployment/web (apps/v1) namespace: demo'
expect_line changes.yaml '# create: secret/creds (v1) namespace: demo'

# Identical inputs produce only no-op entries.
run tools diff -f live.yaml --file2 live.yaml --json >"$work/same.json" ||
  fail "tools diff of identical inputs failed: $(cat "$work/same.json")"
summary=$(jq -r '.Tables[0].Notes[0]' "$work/same.json")
test "$summary" = 'Op:      0 create, 0 delete, 0 update, 3 noop, 0 exists' ||
  fail "identical inputs were not all no-ops: $summary"

# The built-in deploy configuration is the kapp Config with rebase rules.
run deploy-config >"$work/deploy-config.yaml" 2>&1 ||
  fail "deploy-config failed: $(cat "$work/deploy-config.yaml")"
expect_line deploy-config.yaml 'apiVersion: kapp.k14s.io/v1alpha1'
expect_line deploy-config.yaml 'kind: Config'
expect_line deploy-config.yaml 'rebaseRules:'

run completion bash >"$work/completion.bash" 2>&1 ||
  fail "completion bash failed: $(cat "$work/completion.bash")"
expect_line completion.bash '# bash completion for kapp'

# Invalid input and invalid commands fail with a diagnostic.
expect_fail broken tools inspect -f broken.yaml
expect_line broken 'kapp: Error: error converting YAML to JSON'
expect_fail missing tools inspect -f missing.yaml
expect_line missing 'missing.yaml: no such file or directory'
expect_fail bogus no-such-command
expect_line bogus 'kapp: Error: Invalid command'

# Cluster commands without a kubeconfig fail before any network access.
expect_fail no-config list
expect_line no-config 'no configuration has been provided'

# An unreachable cluster fails promptly through each kubeconfig source.
expect_fail refused-file list --kubeconfig kubeconfig
expect_line refused-file 'https://127.0.0.1:1/api/v1/namespaces/demo/configmaps'
expect_line refused-file 'connect: connection refused'

rc=0
docker run --rm --network none --read-only --cap-drop=ALL \
  -e KAPP_KUBECONFIG_YAML="$(cat "$work/in/kubeconfig")" "$image" list \
  >"$work/refused-env" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'list via KAPP_KUBECONFIG_YAML unexpectedly succeeded'
expect_line refused-env 'connect: connection refused'

expect_fail refused-deploy deploy -a web -f app.yaml --kubeconfig kubeconfig -y
expect_line refused-deploy "Target cluster 'https://127.0.0.1:1'"
expect_line refused-deploy 'Getting app:'
expect_line refused-deploy 'configmaps/web.apps.k14s.io'
expect_line refused-deploy 'connect: connection refused'

expect_fail unresolvable list --kubeconfig-yaml \
  "$(sed 's#https://127.0.0.1:1#https://kube.invalid:6443#' "$work/in/kubeconfig")"
expect_line unresolvable 'lookup kube.invalid'

# Live cluster: etcd and kube-apiserver with a static admin token. kapp runs on
# the cluster network on a read-only root with no capabilities. Only resources
# that need no controller are used, so readiness depends on kapp alone.

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

mkdir -p "$work/pki" "$work/kube" "$work/live"
openssl genrsa -out "$work/pki/sa.key" 2048 2>/dev/null ||
  fail 'could not generate the service account key'
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
      namespace: default
current-context: smoke
EOF

# Version 1: a ConfigMap and a Secret. Version 2 changes the ConfigMap and drops
# the Secret. A ConfigMap with an invalid name is rejected by the API server.
cat >"$work/live/v1.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: web
  namespace: demo
data:
  greeting: hello
---
apiVersion: v1
kind: Secret
metadata:
  name: creds
  namespace: demo
stringData:
  password: hunter2
EOF
sed 's/greeting: hello/greeting: goodbye/' "$work/live/v1.yaml" | sed '/^---$/,$d' >"$work/live/v2.yaml"
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: Not_Valid\n  namespace: demo\n' \
  >"$work/live/invalid.yaml"
chmod -R a+rX "$work/pki" "$work/kube" "$work/live"

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

live() {
  docker run --rm --network "$network" --read-only --cap-drop=ALL --tmpfs /tmp \
    -v "$work/kube:/kube:ro" -v "$work/live:/work:ro" "$image" "$@" --kubeconfig /kube/config
}

i=0
until kubectl get --raw /readyz >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'kube-apiserver did not become ready'
  sleep 2
done
kubectl create namespace demo >/dev/null || fail 'could not create the demo namespace'

live deploy -a smoke -f v1.yaml -y >"$work/deploy1" 2>&1 ||
  fail "first deploy failed: $(cat "$work/deploy1")"
expect_line deploy1 'Succeeded'
test "$(kubectl get configmap web -n demo -o jsonpath='{.data.greeting}')" = hello ||
  fail 'deployed ConfigMap does not hold the first greeting'
test "$(kubectl get secret creds -n demo -o jsonpath='{.data.password}' | base64 -d)" = hunter2 ||
  fail 'deployed Secret does not hold the password'
test "$(kubectl get configmap web -n demo -o jsonpath='{.metadata.labels.kapp\.k14s\.io/app}')" != '' ||
  fail 'deployed ConfigMap lacks the kapp app label'

live list --json >"$work/list.json" 2>&1 || fail "list failed: $(cat "$work/list.json")"
test "$(jq -r '[.Tables[0].Rows[].name] | join(",")' "$work/list.json")" = smoke ||
  fail "list does not show exactly the smoke app: $(cat "$work/list.json")"
live inspect -a smoke --json >"$work/inspect.json" 2>&1 ||
  fail "inspect failed: $(cat "$work/inspect.json")"
test "$(jq -r '[.Tables[0].Rows[] | "\(.kind)/\(.name)"] | sort | join(",")' "$work/inspect.json")" = \
  'ConfigMap/web,Secret/creds' || fail "inspect does not show the app resources: $(cat "$work/inspect.json")"

# Redeploying the same input changes nothing.
live deploy -a smoke -f v1.yaml -y >"$work/deploy-same" 2>&1 ||
  fail "unchanged redeploy failed: $(cat "$work/deploy-same")"
expect_line deploy-same 'Op:      0 create, 0 delete, 0 update, 0 noop, 0 exists'

# Version 2 updates the ConfigMap and deletes the dropped Secret.
live deploy -a smoke -f v2.yaml -y >"$work/deploy2" 2>&1 ||
  fail "update deploy failed: $(cat "$work/deploy2")"
expect_line deploy2 'Op:      0 create, 1 delete, 1 update, 0 noop, 0 exists'
test "$(kubectl get configmap web -n demo -o jsonpath='{.data.greeting}')" = goodbye ||
  fail 'update deploy did not change the ConfigMap'
if kubectl get secret creds -n demo >/dev/null 2>&1; then
  fail 'update deploy did not delete the dropped Secret'
fi

# The API server rejects an invalid object; kapp reports it and exits non-zero.
rc=0
live deploy -a broken -f invalid.yaml -y >"$work/deploy-invalid" 2>&1 || rc=$?
test "$rc" -ne 0 || fail "invalid deploy unexpectedly succeeded: $(cat "$work/deploy-invalid")"
expect_line deploy-invalid 'Not_Valid'

live delete -a smoke -y >"$work/delete" 2>&1 || fail "delete failed: $(cat "$work/delete")"
expect_line delete 'Succeeded'
if kubectl get configmap web -n demo >/dev/null 2>&1; then
  fail 'delete left the app ConfigMap behind'
fi
live list --json >"$work/list-after.json" 2>&1 || fail "list after delete failed: $(cat "$work/list-after.json")"
jq -e '[.Tables[0].Rows[].name] | index("smoke") == null' "$work/list-after.json" >/dev/null ||
  fail "deleted app is still listed: $(cat "$work/list-after.json")"

printf 'SMOKE PASS image=%s\n' "$image"
