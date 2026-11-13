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
network="verity-kcsr-$id"
etcd="verity-kcsr-etcd-$id"
api="verity-kcsr-api-$id"
approver="verity-kcsr-approver-$id"
work=$(mktemp -d)

# The node's DNS name resolves to node_ip inside the approver container.
node_dns=node1.cluster.test
node_ip=10.20.30.40

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  for c in "$approver" "$api"; do
    printf -- '--- %s\n' "$c" >&2
    docker logs "$c" 2>&1 | tail -n 30 >&2 || true
  done
  exit 1
}

cleanup() {
  docker rm -f "$approver" "$api" "$etcd" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

recipe_value() {
  awk -v key="$1" '$1 == key { gsub(/"/, "", $2); print $2; exit }' "$here/../melange.yaml"
}
expected_version=$(recipe_value version:)
expected_commit=$(recipe_value source-commit:)
[ -n "$expected_version" ] || fail 'could not read the recipe version'
[ -n "$expected_commit" ] || fail 'could not read the recipe source commit'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/kubelet-csr-approver"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'CA bundle environment is missing'

run() {
  docker run --rm --network none --read-only --cap-drop=ALL "$@"
}

# CLI surface: the flags the upstream chart sets, and an invalid flag.
run "$image" -h >"$work/help" 2>&1 || true
for flag in -provider-regex -provider-ip-prefixes -bypass-dns-resolution -bypass-hostname-check \
  -max-expiration-sec -allowed-dns-names -skip-deny-step -leader-election -kubeconfig; do
  grep -F -e "  $flag" "$work/help" >/dev/null || fail "help is missing $flag"
done
status=0
run "$image" -definitely-invalid >"$work/invalid" 2>&1 || status=$?
test "$status" = 2 || fail "invalid flag exited $status, want 2"
grep -F 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"

# Outside a cluster the controller logs its build identity, then refuses to start.
status=0
run "$image" >"$work/nocluster" 2>&1 || status=$?
test "$status" -ne 0 || fail 'controller outside a cluster unexpectedly succeeded'
grep -F "refs/tags/v$expected_version" "$work/nocluster" >/dev/null ||
  fail "build ref v$expected_version is missing: $(cat "$work/nocluster")"
grep -F "$expected_commit" "$work/nocluster" >/dev/null ||
  fail "build commit $expected_commit is missing: $(cat "$work/nocluster")"
grep -F 'unable to get kubeconfig' "$work/nocluster" >/dev/null ||
  fail "kubeconfig diagnostic is missing: $(cat "$work/nocluster")"

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

# Control plane: etcd and kube-apiserver with static tokens for an admin, the
# approver, and the kubelet of node1.
mkdir -p "$work/pki" "$work/kube" "$work/csr"
openssl genrsa -out "$work/pki/sa.key" 2048 2>/dev/null || fail 'could not generate the service account key'
newtoken() {
  od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
}
admin_token=$(newtoken)
approver_token=$(newtoken)
node_token=$(newtoken)
{
  printf '%s,verity-admin,verity-admin,system:masters\n' "$admin_token"
  printf '%s,kubelet-csr-approver,kubelet-csr-approver\n' "$approver_token"
  printf '%s,system:node:node1,node1,system:nodes\n' "$node_token"
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
kubeconfig "$approver_token" >"$work/kube/approver"
kubeconfig "$node_token" >"$work/kube/node1"
chmod 0644 "$work/kube/admin" "$work/kube/approver" "$work/kube/node1"

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

# kubectl_as USER ARGS...: run kubectl with the kubeconfig of USER.
kubectl_as() {
  user=$1
  shift
  docker run --rm -i --network "$network" -v "$work/kube:/kube:ro" -e "KUBECONFIG=/kube/$user" \
    "$kubectl_image" "$@"
}

i=0
until kubectl_as admin get --raw /readyz >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'kube-apiserver did not become ready'
  sleep 2
done

# RBAC as the upstream deploy/k8s manifests grant it, and the CSR rights that
# kubeadm grants to nodes.
kubectl_as admin apply -f - >"$work/apply" 2>&1 <<'EOF' || fail "could not create RBAC: $(cat "$work/apply")"
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kubelet-csr-approver
rules:
  - apiGroups: [certificates.k8s.io]
    resources: [certificatesigningrequests]
    verbs: [get, list, watch]
  - apiGroups: [coordination.k8s.io]
    resources: [leases]
    verbs: [create, get, update]
  - apiGroups: [certificates.k8s.io]
    resources: [certificatesigningrequests/approval]
    verbs: [update]
  - apiGroups: [certificates.k8s.io]
    resources: [signers]
    resourceNames: [kubernetes.io/kubelet-serving]
    verbs: [approve]
  - apiGroups: [""]
    resources: [events]
    verbs: [create]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kubelet-csr-approver
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kubelet-csr-approver
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: kubelet-csr-approver
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: nodes-create-csr
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:node-bootstrapper
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: system:nodes
---
# Test-only: let the approver decide kube-apiserver-client CSRs too, so the
# check below fails if it ever acts on a signer other than kubelet-serving.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: smoke-approve-client-signer
rules:
  - apiGroups: [certificates.k8s.io]
    resources: [signers]
    resourceNames: [kubernetes.io/kube-apiserver-client]
    verbs: [approve]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: smoke-approve-client-signer
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: smoke-approve-client-signer
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: kubelet-csr-approver
EOF

# A bad provider IP prefix is rejected at startup with exit status 10.
status=0
docker run --rm --network "$network" --read-only --cap-drop=ALL -v "$work/kube:/kube:ro" \
  -e KUBECONFIG=/kube/approver -e PROVIDER_IP_PREFIXES=not-a-prefix "$image" \
  >"$work/badprefix" 2>&1 || status=$?
test "$status" = 10 || fail "bad IP prefix exited $status, want 10: $(cat "$work/badprefix")"
grep -F 'Unable to parse IP prefix: not-a-prefix' "$work/badprefix" >/dev/null ||
  fail "bad IP prefix diagnostic is missing: $(cat "$work/badprefix")"

# The approver as the chart runs it, configured through environment variables,
# with DNS resolution checks enabled against the container's hosts file.
docker run -d --name "$approver" --network "$network" --read-only --cap-drop=ALL \
  --add-host "$node_dns:$node_ip" -p 127.0.0.1::8080 -p 127.0.0.1::8081 \
  -v "$work/kube:/kube:ro" -e KUBECONFIG=/kube/approver \
  -e 'PROVIDER_REGEX=^node[0-9]+\.cluster\.test$' -e PROVIDER_IP_PREFIXES=10.20.0.0/16 \
  "$image" >/dev/null

probe=$(docker port "$approver" 8081/tcp | head -n 1)
metrics=$(docker port "$approver" 8080/tcp | head -n 1)
[ -n "$probe" ] || fail 'health probe port is not published'
[ -n "$metrics" ] || fail 'metrics port is not published'
i=0
until curl -fsS "http://$probe/healthz" >"$work/healthz" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'approver did not become healthy'
  sleep 2
done
grep -Fx ok "$work/healthz" >/dev/null || fail "unexpected healthz body: $(cat "$work/healthz")"

# csr NAME USER SIGNER USAGES SUBJECT SAN: submit a CSR for a fresh ECDSA key as USER.
csr() {
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$work/csr/$1.key" -out "$work/csr/$1.csr" -subj "$5" \
    -addext "subjectAltName=$6" 2>"$work/csr/$1.err" ||
    fail "openssl could not create CSR $1: $(cat "$work/csr/$1.err")"
  request=$(base64 <"$work/csr/$1.csr" | tr -d '\n')
  kubectl_as "$2" create -f - >"$work/csr/$1.out" 2>&1 <<EOF ||
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: $1
spec:
  request: $request
  signerName: $3
  usages: [$4]
EOF
    fail "could not submit CSR $1: $(cat "$work/csr/$1.out")"
}
serving=kubernetes.io/kubelet-serving
usages='digital signature, server auth'
node_subject='/O=system:nodes/CN=system:node:node1'

# The client CSR goes first, so the approver has seen it before it settles the
# kubelet-serving ones below.
csr client admin kubernetes.io/kube-apiserver-client 'digital signature, client auth' \
  '/O=verity/CN=verity-client' 'DNS:client.cluster.test'
csr good node1 "$serving" "$usages" "$node_subject" "DNS:$node_dns,IP:$node_ip"
csr wrong-dns node1 "$serving" "$usages" "$node_subject" "DNS:evil.example,IP:$node_ip"
csr wrong-domain node1 "$serving" "$usages" "$node_subject" "DNS:node1.evil.example,IP:$node_ip"
csr wrong-host node1 "$serving" "$usages" "$node_subject" "DNS:node2.cluster.test,IP:$node_ip"
csr unresolved-ip node1 "$serving" "$usages" "$node_subject" "DNS:$node_dns,IP:10.20.30.41"
csr outside-ip node1 "$serving" "$usages" "$node_subject" "IP:192.168.7.7"
csr not-a-node admin "$serving" "$usages" '/O=system:nodes/CN=verity-admin' "DNS:$node_dns"

# outcome NAME: print the condition types and the message of a CSR.
outcome() {
  kubectl_as admin get csr "$1" \
    -o 'jsonpath={range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
}

# expect NAME TYPE MESSAGE: wait until CSR NAME carries condition TYPE whose
# text contains MESSAGE, and assert it never carries the opposite one.
expect() {
  i=0
  until outcome "$1" >"$work/csr/$1.status" 2>&1 && grep -F "$2=True" "$work/csr/$1.status" >/dev/null; do
    i=$((i + 1))
    [ "$i" -lt 60 ] || fail "CSR $1 was not $2: $(cat "$work/csr/$1.status")"
    sleep 2
  done
  grep -F "$3" "$work/csr/$1.status" >/dev/null ||
    fail "CSR $1 is $2 without '$3': $(cat "$work/csr/$1.status")"
  case $2 in
    Approved) other=Denied ;;
    *) other=Approved ;;
  esac
  if grep -F "$other=" "$work/csr/$1.status" >/dev/null; then
    fail "CSR $1 is also $other: $(cat "$work/csr/$1.status")"
  fi
}

expect good Approved 'CSR complied with kubelet-csr-approver validation process'
expect wrong-dns Denied 'not prefixed by the node name'
expect wrong-domain Denied 'not allowed by the Cloud provider regex'
expect wrong-host Denied 'not prefixed by the node name'
expect unresolved-ip Denied 'One of the SAN IP addresses, 10.20.30.41, is not contained in the set of resolved IP addresses'
expect outside-ip Denied 'One of the SAN IP addresses, 192.168.7.7, is not part'
expect not-a-node Denied 'CSR Spec.Username is not prefixed with system:node:'

# CSRs for other signers are left alone, although the approver may decide them.
kubectl_as admin create -o 'jsonpath={.status.allowed}' -f - >"$work/sar" 2>&1 <<'EOF' ||
apiVersion: authorization.k8s.io/v1
kind: SubjectAccessReview
spec:
  user: kubelet-csr-approver
  resourceAttributes:
    group: certificates.k8s.io
    resource: signers
    name: kubernetes.io/kube-apiserver-client
    verb: approve
EOF
  fail "could not review the approver's access: $(cat "$work/sar")"
test "$(cat "$work/sar")" = true || fail "approver cannot approve the client signer: $(cat "$work/sar")"
i=0
while [ "$i" -lt 5 ]; do
  outcome client >"$work/csr/client.status" 2>&1 ||
    fail "cannot read CSR client: $(cat "$work/csr/client.status")"
  if [ -s "$work/csr/client.status" ]; then
    fail "the approver acted on a non kubelet-serving CSR: $(cat "$work/csr/client.status")"
  fi
  i=$((i + 1))
  sleep 2
done

# The approval was recorded through the approver identity, and the controller
# exports reconcile metrics.
docker logs "$approver" >"$work/approver.log" 2>&1
grep -F "refs/tags/v$expected_version" "$work/approver.log" >/dev/null ||
  fail 'approver did not log its build ref'
grep -F 'CSR approved' "$work/approver.log" >/dev/null || fail 'approver did not log the approval'
curl -fsS "http://$metrics/metrics" >"$work/metrics" || fail 'metrics endpoint failed'
grep -E '^controller_runtime_reconcile_total\{controller="certificatesigningrequest",result="success"\} [1-9]' \
  "$work/metrics" >/dev/null || fail 'reconcile metrics are missing'

# The approver shuts down cleanly on SIGTERM.
docker stop -t 20 "$approver" >/dev/null || fail 'could not stop the approver'
code=$(docker inspect -f '{{.State.ExitCode}}' "$approver")
test "$code" = 0 || fail "approver exited $code after SIGTERM"

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$expected_version"
