#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# Peers for a real control plane: Verity etcd 3.7, kube-apiserver 1.37 and
# kubectl 1.35, pinned by digest. kor only lists and reads objects, so no
# scheduler or controller-manager is needed: a Pending Pod still references
# its ConfigMaps through the API.
etcd_index=ghcr.io/tektum/etcd@sha256:fc322841b20ac374159333e013fb417aa712e776380c53dc34ab8a1958c07fd2
api_index=ghcr.io/tektum/kube-apiserver@sha256:b46742424f608bb186b83390c41cbe7f97df411ae3cf8fc3e4578c096a6b57bd
kubectl_index=ghcr.io/tektum/kubectl@sha256:537780af388652be3a0130aacd6d1cfed24704ab6a820c6c7024602ec7777332

id=$$
network="verity-kor-$id"
etcd="verity-kor-etcd-$id"
api="verity-kor-api-$id"
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  docker logs "$api" 2>&1 | tail -n 20 >&2 || true
  exit 1
}

cleanup() {
  docker rm -f "$api" "$etcd" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'

# OCI contract: upstream uses ENTRYPOINT ["/usr/bin/kor"] and CMD ["--help"].
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/kor"]' ||
  fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["--help"]' ||
  fail 'unexpected default command'

run() {
  docker run --rm --read-only --cap-drop=ALL --security-opt=no-new-privileges "$@"
}

# Version stamp from the upstream GoReleaser ldflags.
run --network none "$image" version >"$work/version" 2>&1 ||
  fail "version failed: $(cat "$work/version")"
grep -Fx "kor version: v$expected_version" "$work/version" >/dev/null ||
  fail "unexpected version output: $(cat "$work/version")"

# The default command prints help without touching a cluster.
run --network none "$image" >"$work/help" 2>&1 || fail "default --help failed: $(cat "$work/help")"
for word in configmap secret serviceaccount all; do
  grep -E "^  $word " "$work/help" >/dev/null || fail "help is missing $word"
done

# Negative: an unknown flag fails.
status=0
run --network none "$image" configmap --definitely-invalid-flag >"$work/invalid" 2>&1 || status=$?
test "$status" -ne 0 || fail 'unknown flag unexpectedly succeeded'
grep -F 'unknown flag: --definitely-invalid-flag' "$work/invalid" >/dev/null ||
  fail "missing unknown-flag diagnostic: $(cat "$work/invalid")"

# Negative: a malformed kubeconfig fails before any scan output.
mkdir -p "$work/pki" "$work/kube" "$work/bad"
printf 'apiVersion: [' >"$work/bad/config"
chmod 0755 "$work/bad" && chmod 0644 "$work/bad/config"
status=0
run --network none -v "$work/bad:/kube:ro" "$image" \
  configmap --kubeconfig /kube/config -o json >"$work/badcfg" 2>&1 || status=$?
test "$status" -ne 0 || fail "malformed kubeconfig unexpectedly succeeded: $(cat "$work/badcfg")"
grep -F 'Failed to load kubeconfig' "$work/badcfg" >/dev/null ||
  fail "missing kubeconfig diagnostic: $(cat "$work/badcfg")"

# Control plane: etcd and kube-apiserver with a static admin token.
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
chmod 0755 "$work/pki" "$work/kube"
chmod 0644 "$work/pki/sa.key" "$work/pki/tokens.csv" "$work/kube/config"

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

i=0
until kubectl get --raw /readyz >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'kube-apiserver did not become ready'
  sleep 2
done

# Fixture: one ConfigMap mounted by a Pod (used) and one referenced by nothing
# (unused). The default ServiceAccount is created by hand because no
# controller-manager runs.
kubectl apply -f - >/dev/null <<'EOF' || fail 'cannot apply the fixture'
apiVersion: v1
kind: Namespace
metadata:
  name: shop
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
  namespace: shop
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: used-config
  namespace: shop
data:
  key: value
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: orphan-config
  namespace: shop
data:
  key: value
---
apiVersion: v1
kind: Pod
metadata:
  name: web
  namespace: shop
spec:
  automountServiceAccountToken: false
  containers:
    - name: web
      image: registry.invalid/web:1
      volumeMounts:
        - name: cfg
          mountPath: /cfg
  volumes:
    - name: cfg
      configMap:
        name: used-config
EOF

in_cluster() {
  run --network "$network" -v "$work/kube:/kube:ro" "$image" "$@"
}

# JSON report: exactly the orphan ConfigMap is unused in namespace shop.
in_cluster configmap --kubeconfig /kube/config --include-namespaces shop -o json \
  >"$work/report.json" 2>"$work/report.err" ||
  fail "configmap scan failed: $(cat "$work/report.err")"
jq -e '.shop.ConfigMap == ["orphan-config"]' "$work/report.json" >/dev/null ||
  fail "unexpected JSON report: $(cat "$work/report.json")"

# Table report with reasons, via KUBECONFIG instead of the flag.
run --network "$network" -v "$work/kube:/kube:ro" -e KUBECONFIG=/kube/config "$image" \
  configmap --include-namespaces shop --show-reason >"$work/report.txt" 2>&1 ||
  fail "table scan failed: $(cat "$work/report.txt")"
grep -F 'orphan-config' "$work/report.txt" >/dev/null ||
  fail "table report is missing orphan-config: $(cat "$work/report.txt")"
if grep -F 'used-config' "$work/report.txt" | grep -Fv 'orphan-config' >/dev/null; then
  fail "table report flags the mounted ConfigMap: $(cat "$work/report.txt")"
fi
grep -F "kor version: v$expected_version" "$work/report.txt" >/dev/null ||
  fail "table report is missing the version banner: $(cat "$work/report.txt")"

# Negative: a well-formed kubeconfig with a wrong token is rejected by the
# API server. Upstream v0.7.0 single-resource scans log the error and exit 0
# with an empty report, so assert the diagnostic and that no cluster data
# leaks; the `all` scan does propagate the failure as a non-zero exit.
sed "s/token: $token/token: wrong-$token/" "$work/kube/config" >"$work/bad/config"
run --network "$network" -v "$work/bad:/kube:ro" "$image" \
  configmap --kubeconfig /kube/config -o json >"$work/unauth" 2>&1 || true
grep -F 'Failed to retrieve namespaces: Unauthorized' "$work/unauth" >/dev/null ||
  fail "missing authentication diagnostic: $(cat "$work/unauth")"
if grep -F 'orphan-config' "$work/unauth" >/dev/null; then
  fail "unauthenticated scan leaked cluster data: $(cat "$work/unauth")"
fi
status=0
run --network "$network" -v "$work/bad:/kube:ro" "$image" \
  all --kubeconfig /kube/config -o json >"$work/unauth-all" 2>&1 || status=$?
test "$status" -ne 0 || fail "unauthenticated full scan unexpectedly succeeded: $(cat "$work/unauth-all")"
grep -F 'Unauthorized' "$work/unauth-all" >/dev/null ||
  fail "missing full-scan authentication diagnostic: $(cat "$work/unauth-all")"

printf 'SMOKE PASS image=%s\n' "$image"
