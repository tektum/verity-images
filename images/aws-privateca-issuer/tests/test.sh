#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# Peers for a real control plane: Verity etcd 3.7, kube-apiserver 1.37 and
# kubectl 1.35, pinned by digest. Everything runs on an internal Docker network
# with no route out, so no AWS endpoint (STS, Private CA, IMDS) is reachable and
# the test never makes an AWS call.
etcd_index=ghcr.io/tektum/etcd@sha256:fc322841b20ac374159333e013fb417aa712e776380c53dc34ab8a1958c07fd2
api_index=ghcr.io/tektum/kube-apiserver@sha256:b46742424f608bb186b83390c41cbe7f97df411ae3cf8fc3e4578c096a6b57bd
kubectl_index=ghcr.io/tektum/kubectl@sha256:537780af388652be3a0130aacd6d1cfed24704ab6a820c6c7024602ec7777332

id=$$
network="verity-pcai-$id"
etcd="verity-pcai-etcd-$id"
api="verity-pcai-api-$id"
op="verity-pcai-op-$id"
nocrd="verity-pcai-nocrd-$id"
badtoken="verity-pcai-badtoken-$id"
work=$(mktemp -d)
ns=pca-smoke
arn=arn:aws:acm-pca:us-east-1:111122223333:certificate-authority/11111111-2222-3333-4444-555555555555

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  for c in "$op" "$api"; do
    printf -- '--- %s\n' "$c" >&2
    docker logs "$c" 2>&1 | tail -n 40 >&2 || true
  done
  exit 1
}

cleanup() {
  docker rm -f "$op" "$nocrd" "$badtoken" "$api" "$etcd" >/dev/null 2>&1 || true
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
  '["/usr/bin/aws-privateca-issuer"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = / ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'CA bundle environment is missing'

# Upstream's deployment runs as 65532 with a read-only root and no
# capabilities; do the same everywhere.
run() {
  docker run --rm --network none --read-only --cap-drop=ALL "$@"
}

# CLI surface: Go flag parsing, as upstream.
run "$image" --help >"$work/help" 2>&1 || true
for flag in -metrics-bind-address -health-probe-bind-address -leader-elect \
  -disable-approved-check -cluster-issuer-ambient-credentials \
  -issuer-ambient-credentials -kubeconfig -zap-log-level; do
  grep -F -e "$flag" "$work/help" >/dev/null || fail "help is missing $flag"
done
status=0
run "$image" --definitely-invalid >"$work/invalid" 2>&1 || status=$?
test "$status" -eq 2 || fail "invalid flag exited $status, want 2"
grep -F 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"

# Upstream's chart runs command: /manager; that path still runs.
run --entrypoint /manager "$image" --help >/dev/null 2>&1 || true
run --entrypoint /manager "$image" --help 2>&1 | grep -F -- '-leader-elect' >/dev/null ||
  fail 'compatibility path /manager does not run'

# Without any cluster configuration the manager fails fast instead of waiting.
status=0
timeout 30 docker run --rm --network none --read-only --cap-drop=ALL "$image" \
  >"$work/nocluster" 2>&1 || status=$?
test "$status" -ne 0 || fail 'manager without a cluster unexpectedly succeeded'
test "$status" -ne 124 || fail 'manager without a cluster did not exit within 30s'
grep -F 'unable to get kubeconfig' "$work/nocluster" >/dev/null ||
  fail "missing kubeconfig diagnostic: $(cat "$work/nocluster")"

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

# The image ships the issuer CRDs of this release and the cert-manager
# CertificateRequest CRD of the cert-manager module it is compiled against.
mkdir -p "$work/crds" "$work/cmcrds"
holder=$(docker create "$image") || fail 'could not create a container from the image'
docker cp "$holder:/usr/share/aws-privateca-issuer/crds/." "$work/crds/" >/dev/null 2>&1 ||
  { docker rm "$holder" >/dev/null; fail 'image does not ship the issuer CRDs'; }
docker cp "$holder:/usr/share/aws-privateca-issuer/cert-manager-crds/." "$work/cmcrds/" \
  >/dev/null 2>&1 ||
  { docker rm "$holder" >/dev/null; fail 'image does not ship the CertificateRequest CRD'; }
docker rm "$holder" >/dev/null
for crd in awspca.cert-manager.io_awspcaissuers awspca.cert-manager.io_awspcaclusterissuers; do
  [ -s "$work/crds/$crd.yaml" ] || fail "missing CRD $crd.yaml"
done
[ -s "$work/cmcrds/cert-manager.io_certificaterequests.yaml" ] ||
  fail 'missing CRD cert-manager.io_certificaterequests.yaml'
chmod -R a+rX "$work/crds" "$work/cmcrds"

# Control plane: etcd and kube-apiserver with static tokens. No scheduler or
# kubelet runs. The internal network has no default route, so the API server
# cannot pick an advertise address by itself; give it a fixed address in the
# network's subnet.
mkdir -p "$work/pki" "$work/kube" "$work/badkube" "$work/manifests"
openssl genrsa -out "$work/pki/sa.key" 2048 2>/dev/null ||
  fail 'could not generate the service account key'
token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
printf '%s,verity-admin,verity-admin,system:masters\n' "$token" >"$work/pki/tokens.csv"
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
  - name: admin
    user:
      token: $1
contexts:
  - name: smoke
    context:
      cluster: smoke
      user: admin
current-context: smoke
EOF
}
kubeconfig "$token" >"$work/kube/config"
kubeconfig "not-$token" >"$work/badkube/config"
chmod 0755 "$work/kube" "$work/badkube"
chmod 0644 "$work/kube/config" "$work/badkube/config"

# An internal network has no default route, so kube-apiserver cannot pick its
# advertise address, and Docker only accepts --ip on a network with a
# user-configured subnet. Give the network an explicit random 10.x.y.0/24
# (retrying on overlap with an existing network) and pin the API server's address.
subnet=
i=0
while [ "$i" -lt 10 ]; do
  candidate=$(od -An -N2 -tu1 /dev/urandom | awk '{ print "10." $1 "." $2 }')
  if docker network create --internal --subnet "$candidate.0/24" "$network" >/dev/null 2>&1; then
    subnet=$candidate
    break
  fi
  i=$((i + 1))
done
[ -n "$subnet" ] || fail 'could not create the internal network'
api_ip="$subnet.10"
docker run -d --name "$etcd" --network "$network" --tmpfs /var/lib/etcd:uid=65532,gid=65532 \
  "$etcd_image" --data-dir=/var/lib/etcd/data \
  --listen-client-urls=http://0.0.0.0:2379 --advertise-client-urls="http://$etcd:2379" >/dev/null
docker run -d --name "$api" --network "$network" --ip "$api_ip" --tmpfs /tmp:uid=65532,gid=65532 \
  -v "$work/pki:/pki:ro" "$api_image" \
  --advertise-address="$api_ip" --etcd-servers="http://$etcd:2379" --secure-port=6443 --cert-dir=/tmp \
  --token-auth-file=/pki/tokens.csv --authorization-mode=RBAC \
  --service-account-issuer=https://kubernetes.default.svc \
  --service-account-key-file=/pki/sa.key --service-account-signing-key-file=/pki/sa.key \
  --service-cluster-ip-range=10.96.0.0/16 >/dev/null

kubectl() {
  docker run --rm -i --network "$network" -v "$work/kube:/kube:ro" \
    -v "$work/crds:/crds:ro" -v "$work/cmcrds:/cmcrds:ro" -v "$work/manifests:/m:ro" \
    -e KUBECONFIG=/kube/config "$kubectl_image" "$@"
}

i=0
until kubectl get --raw /readyz >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'kube-apiserver did not become ready'
  sleep 2
done

kubectl apply -f /crds >"$work/crd" 2>&1 || fail "could not create the issuer CRDs: $(cat "$work/crd")"
kubectl wait --for=condition=Established --timeout=60s \
  crd/awspcaissuers.awspca.cert-manager.io crd/awspcaclusterissuers.awspca.cert-manager.io \
  >/dev/null || fail 'issuer CRDs were not established'

# manager NAME KUBEDIR [ARGS...]: run the manager out of cluster, read-only,
# with no capabilities, no AWS credentials and IMDS disabled.
manager() {
  name=$1
  kubedir=$2
  shift 2
  docker run -d --name "$name" --network "$network" --read-only --cap-drop=ALL \
    -v "$kubedir:/kube:ro" -e KUBECONFIG=/kube/config -e AWS_EC2_METADATA_DISABLED=true \
    "$image" --metrics-bind-address=0 "$@" >/dev/null
}

# exited NAME SECONDS: wait for a container to exit; fail if it keeps running.
exited() {
  i=0
  while running=$(docker inspect --format '{{.State.Running}}' "$1") && [ "$running" = true ]; do
    i=$((i + 1))
    [ "$i" -lt "$2" ] || fail "$1 kept running for ${2}s"
    sleep 1
  done
  code=$(docker inspect --format '{{.State.ExitCode}}' "$1")
  test "$code" -ne 0 || fail "$1 exited 0"
}

# Credentials the API server rejects: the manager reports the rejection and
# never starts its workers (it keeps retrying, as controller-runtime does).
manager "$badtoken" "$work/badkube"
i=0
until docker logs "$badtoken" 2>&1 | grep -F 'the server has asked for the client to provide credentials' >/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail "no unauthorized diagnostic: $(docker logs "$badtoken" 2>&1 | tail -n 5)"
  sleep 1
done
! docker logs "$badtoken" 2>&1 | grep -F 'Starting workers' >/dev/null ||
  fail 'manager started workers with rejected credentials'
docker rm -f "$badtoken" >/dev/null

# Without the cert-manager CertificateRequest CRD the manager gives up when
# its cache sync timeout (2 minutes) expires, and exits non-zero.
manager "$nocrd" "$work/kube"
exited "$nocrd" 180
docker logs "$nocrd" >"$work/nocrd" 2>&1
grep -F 'Could not wait for Cache to sync' "$work/nocrd" |
  grep -F '"controllerKind":"CertificateRequest"' >/dev/null ||
  fail "missing CertificateRequest cache diagnostic: $(tail -n 5 "$work/nocrd")"

kubectl apply -f /cmcrds >"$work/cmcrd" 2>&1 ||
  fail "could not create the CertificateRequest CRD: $(cat "$work/cmcrd")"
kubectl wait --for=condition=Established --timeout=60s \
  crd/certificaterequests.cert-manager.io >/dev/null ||
  fail 'CertificateRequest CRD was not established'

# Debug verbosity (V(4)) logs the reconciler's early exit for an unapproved
# request, the positive signal that the approval gate was exercised.
manager "$op" "$work/kube" --zap-log-level=4
i=0
until docker logs "$op" 2>&1 | grep -F 'Starting workers' | grep -F 'certificaterequest' >/dev/null; do
  i=$((i + 1))
  [ "$(docker inspect --format '{{.State.Running}}' "$op")" = true ] || fail 'manager exited'
  [ "$i" -lt 60 ] || fail 'manager did not start its workers'
  sleep 1
done

# Issuers that each stop before any AWS call: a missing ARN, no credentials
# with namespaced ambient credentials off (the default), a Secret that does
# not exist, and a Secret without a secret access key.
cat >"$work/manifests/issuers.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $ns
---
apiVersion: v1
kind: Secret
metadata:
  name: partial
  namespace: $ns
stringData:
  AWS_ACCESS_KEY_ID: AKIAVERITYSMOKETEST
---
apiVersion: awspca.cert-manager.io/v1beta1
kind: AWSPCAIssuer
metadata:
  name: noarn
  namespace: $ns
spec:
  region: us-east-1
---
apiVersion: awspca.cert-manager.io/v1beta1
kind: AWSPCAIssuer
metadata:
  name: ambient
  namespace: $ns
spec:
  arn: $arn
  region: us-east-1
---
apiVersion: awspca.cert-manager.io/v1beta1
kind: AWSPCAIssuer
metadata:
  name: nosecret
  namespace: $ns
spec:
  arn: $arn
  region: us-east-1
  secretRef:
    name: missing
---
apiVersion: awspca.cert-manager.io/v1beta1
kind: AWSPCAIssuer
metadata:
  name: nokey
  namespace: $ns
spec:
  arn: $arn
  region: us-east-1
  secretRef:
    name: partial
EOF
chmod 0644 "$work/manifests/issuers.yaml"
kubectl apply -f /m/issuers.yaml >"$work/apply" 2>&1 ||
  fail "could not create the issuers: $(cat "$work/apply")"

# ready_condition KIND NAME: print the Ready condition as reason|message.
ready_condition() {
  kubectl get "$1" -n "$ns" "$2" \
    -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}|{.reason}|{.message}{end}' \
    2>/dev/null
}

# expect_ready KIND NAME EXPECTED: wait until the Ready condition is EXPECTED.
expect_ready() {
  i=0
  until [ "$(ready_condition "$1" "$2")" = "$3" ]; do
    i=$((i + 1))
    [ "$i" -lt 60 ] ||
      fail "$1/$2 Ready is '$(ready_condition "$1" "$2")', want '$3'"
    sleep 1
  done
}

expect_ready awspcaissuer noarn 'False|Validation|Failed to validate resource: no Arn found in Issuer Spec'
expect_ready awspcaissuer ambient 'False|Error|empty credentials; perhaps you meant to enable ambient credentials?'
expect_ready awspcaissuer nosecret \
  'False|Error|failed to retrieve secret: Secret "missing" not found'
expect_ready awspcaissuer nokey 'False|Error|no AWS Secret Access Key Found'

# CertificateRequests: one left unapproved, one approved against an issuer
# that is not ready, and one naming an issuer kind this controller does not own.
openssl req -new -newkey rsa:2048 -nodes -subj '/CN=smoke.example.com' \
  -keyout "$work/csr.key" -out "$work/csr.pem" >/dev/null 2>&1 || fail 'could not generate a CSR'
csr=$(base64 <"$work/csr.pem" | tr -d '\n')
for req in unapproved:AWSPCAIssuer pending:AWSPCAIssuer bogus:Bogus; do
  cat <<EOF
---
apiVersion: cert-manager.io/v1
kind: CertificateRequest
metadata:
  name: ${req%%:*}
  namespace: $ns
spec:
  request: $csr
  usages: [digital signature, key encipherment, server auth]
  issuerRef:
    group: awspca.cert-manager.io
    kind: ${req#*:}
    name: ambient
EOF
done >"$work/manifests/requests.yaml"
chmod 0644 "$work/manifests/requests.yaml"
kubectl apply -f /m/requests.yaml >"$work/apply" 2>&1 ||
  fail "could not create the CertificateRequests: $(cat "$work/apply")"
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for cr in pending bogus; do
  kubectl patch certificaterequest -n "$ns" "$cr" --subresource=status --type=merge -p \
    "{\"status\":{\"conditions\":[{\"type\":\"Approved\",\"status\":\"True\",\"reason\":\"Smoke\",\"message\":\"approved by the smoke test\",\"lastTransitionTime\":\"$now\"}]}}" \
    >/dev/null || fail "could not approve $cr"
done

expect_ready certificaterequest pending 'False|Pending|issuer is not ready'
expect_ready certificaterequest bogus 'False|Failed|unsupported issuer kind: Bogus'
# The approval check is on by default: the unapproved request is left alone.
# Wait until the controller has reconciled it and taken the not-approved exit
# before asserting that nothing was written to it.
i=0
until docker logs "$op" 2>&1 | grep -F 'certificate request has not been approved' |
  grep -F '"name":"unapproved"' >/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'controller never reconciled the unapproved request'
  sleep 1
done
[ -z "$(ready_condition certificaterequest unapproved)" ] ||
  fail "unapproved request was processed: $(ready_condition certificaterequest unapproved)"
kubectl get certificaterequest -n "$ns" unapproved -o jsonpath='{.status.certificate}' \
  >"$work/cert" || fail 'could not read the unapproved request'
[ ! -s "$work/cert" ] || fail 'unapproved request received a certificate'

# Nothing reached AWS: no STS identity was ever logged, and the manager is
# still running.
docker logs "$op" >"$work/op" 2>&1
! grep -F 'sts.GetCallerIdentity' "$work/op" >/dev/null || fail 'manager attempted an STS call'
[ "$(docker inspect --format '{{.State.Running}}' "$op")" = true ] || fail 'manager exited'

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$expected_version"
