#!/bin/sh
set -eu

# Out-of-cluster behavior that needs no AWS account. A pinned Verity etcd and
# kube-apiserver provide a real API server on a per-test internal bridge network
# with no route out, so the EC2 metadata service and AWS endpoints are never
# reachable, on any runner. The aws-cloud-controller-manager must:
#   - keep the upstream registry.k8s.io/provider-aws/cloud-controller-manager
#     entrypoint, report its version, and fail fast on unknown flags;
#   - fail fast without a kubeconfig, on a missing, unparsable, or invalid
#     cloud config, on an invalid zone, on endpoint overrides without a URL, and
#     without a cloud config when no EC2 metadata service is reachable;
#   - start with the upstream example manifest arguments and leader election on
#     a read-only root filesystem as UID 65532, take the
#     leader lease, serve /healthz and /metrics on secure port 10258 with
#     delegated authentication and authorization, and reject anonymous /metrics;
#   - run its AWS service controller: a LoadBalancer Service gets the cleanup
#     finalizer and a SyncLoadBalancerFailed event from the AWS provider;
#   - exit promptly on SIGTERM as PID 1.

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

etcd_index=ghcr.io/tektum/etcd@sha256:fc322841b20ac374159333e013fb417aa712e776380c53dc34ab8a1958c07fd2
api_index=ghcr.io/tektum/kube-apiserver@sha256:b46742424f608bb186b83390c41cbe7f97df411ae3cf8fc3e4578c096a6b57bd
curl_index='docker.io/curlimages/curl:8.14.1@sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b'

id=$$
label="verity-test=cloud-provider-aws-$id"
network="verity-awsccm-$id"
etcd="verity-awsccm-etcd-$id"
api="verity-awsccm-api-$id"
ccm="verity-awsccm-ccm-$id"
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  for c in "$ccm" "$api"; do
    printf -- '--- %s\n' "$c" >&2
    docker logs "$c" 2>&1 | tail -n 30 >&2 || true
  done
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

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] ||
  fail 'unexpected OCI user'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/bin/aws-cloud-controller-manager"]' ] || fail 'unexpected entrypoint'
[ "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ] ||
  fail 'unexpected default command'
case $(docker image inspect --format '{{.Config.WorkingDir}}' "$image") in
  '' | /) ;;
  *) fail 'unexpected working directory' ;;
esac

# out NAME ARGS...: run the image under a 60s bound; record status and output.
# A timeout is a failure: every case here must exit on its own.
out() {
  name=$1
  shift
  status=0
  timeout 60 docker run --rm --label "$label" --read-only --cap-drop=ALL "$@" \
    >"$work/$name.out" 2>&1 || status=$?
  [ "$status" != 124 ] || fail "$name: timed out"
}

expect_fail() {
  name=$1
  message=$2
  shift 2
  out "$name" "$@"
  [ "$status" != 0 ] || fail "$name: unexpectedly succeeded"
  grep -qF -- "$message" "$work/$name.out" ||
    fail "$name: missing '$message': $(grep -vE '^[[:space:]]|^goroutine|^I[0-9]{4}' "$work/$name.out" | head -n 8)"
}

out version --network none "$image" --version
[ "$status" = 0 ] || fail "version exited $status"
[ "$(cat "$work/version.out")" = "Kubernetes v${expected_version}" ] ||
  fail "unexpected version: $(cat "$work/version.out")"

out help --network none "$image" --help
[ "$status" = 0 ] || fail "help exited $status"
for flag in --cloud-provider --cloud-config --configure-cloud-routes \
  --use-service-account-credentials --tags --resources; do
  grep -qF -- "$flag" "$work/help.out" || fail "help is missing $flag"
done

expect_fail unknown-flag 'unknown flag: --no-such-flag' --network none "$image" --no-such-flag
expect_fail no-kubeconfig 'invalid configuration: no configuration has been provided' \
  --network none "$image" --v=2 --cloud-provider=aws

# image_arch, pull_child: resolve each pinned helper index to the candidate's
# platform child, verifying the index bytes against the pin. A classic Docker
# store cannot bind one index digest to a second platform's image.
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
etcd_image=$(pull_child "$etcd_index") || exit 1
api_image=$(pull_child "$api_index") || exit 1
curl_image=$(pull_child "$curl_index") || exit 1

mkdir -p "$work/pki" "$work/kube" "$work/cfg"
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

# Cloud configs (gcfg INI). The valid one names its zone, VPC, subnet, and
# cluster ID, which upstream documents for a control plane that cannot reach the
# EC2 metadata service, so initialization makes no AWS call.
cat >"$work/cfg/valid.conf" <<'EOF'
[Global]
Zone = us-east-1a
VPC = vpc-0123456789abcdef0
SubnetID = subnet-0123456789abcdef0
KubernetesClusterID = verity-smoke
EOF
printf '[Global]\nthis is not = [ini\n' >"$work/cfg/garbage.conf"
printf '[Global]\nZone = not-a-zone\nKubernetesClusterID = verity-smoke\n' >"$work/cfg/badzone.conf"
printf '[ServiceOverride "1"]\nService = ec2\nRegion = us-east-1\n' >"$work/cfg/badoverride.conf"
chmod -R a+rX "$work"

# An internal network has no default route, so kube-apiserver cannot pick its
# advertise address. Give the network an explicit random 10.x.y.0/24 (retrying
# on overlap with an existing network) and pin the API server's address.
subnet=
i=0
while [ "$i" -lt 10 ]; do
  # shellcheck disable=SC2046
  set -- $(od -An -N2 -tu1 /dev/urandom)
  candidate="10.$1.$2"
  if docker network create --internal --label "$label" --subnet "$candidate.0/24" \
    "$network" >/dev/null 2>&1; then
    subnet=$candidate
    break
  fi
  i=$((i + 1))
done
[ -n "$subnet" ] || fail 'could not create the internal network'
api_ip="$subnet.10"
docker run -d --label "$label" --name "$etcd" --network "$network" \
  --tmpfs /var/lib/etcd:uid=65532,gid=65532 "$etcd_image" --data-dir=/var/lib/etcd/data \
  --listen-client-urls=http://0.0.0.0:2379 --advertise-client-urls="http://$etcd:2379" >/dev/null ||
  fail 'etcd did not start'
docker run -d --label "$label" --name "$api" --network "$network" --ip "$api_ip" \
  --tmpfs /tmp:uid=65532,gid=65532 -v "$work/pki:/pki:ro" "$api_image" --advertise-address="$api_ip" \
  --etcd-servers="http://$etcd:2379" --secure-port=6443 --cert-dir=/tmp \
  --token-auth-file=/pki/tokens.csv --authorization-mode=RBAC \
  --service-account-issuer=https://kubernetes.default.svc \
  --service-account-key-file=/pki/sa.key --service-account-signing-key-file=/pki/sa.key \
  --service-cluster-ip-range=10.96.0.0/16 >/dev/null || fail 'kube-apiserver did not start'

# kube API helper: kube METHOD PATH [JSON] prints the body, then the status code.
kube() {
  if [ $# -ge 3 ]; then
    docker run --rm --label "$label" --network "$network" "$curl_image" -sk --max-time 10 \
      -X "$1" -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
      --data "$3" -o /dev/stdout -w '\n%{http_code}' "https://$api:6443$2" 2>/dev/null || true
  else
    docker run --rm --label "$label" --network "$network" "$curl_image" -sk --max-time 10 \
      -X "$1" -H "Authorization: Bearer $token" \
      -o /dev/stdout -w '\n%{http_code}' "https://$api:6443$2" 2>/dev/null || true
  fi
}
code_of() { printf '%s\n' "$1" | tail -n 1; }
body_of() { printf '%s\n' "$1" | sed '$d'; }

i=0
until [ "$(code_of "$(kube GET /readyz)")" = 200 ]; do
  [ "$(docker inspect -f '{{.State.Running}}' "$api" 2>/dev/null)" = true ] ||
    fail 'kube-apiserver exited before it was ready'
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'kube-apiserver did not become ready'
  sleep 2
done

# Upstream's examples/existing-cluster manifest passes --v=2 --cloud-provider=aws
# --configure-cloud-routes=false (and per-controller service accounts, which need
# its RBAC manifests; the admin kubeconfig replaces both). No --cert-dir: the
# secure port must serve with in-memory certificates on a read-only root.
ccm_args="--v=2 --cloud-provider=aws --configure-cloud-routes=false --kubeconfig=/kube/config
  --authentication-kubeconfig=/kube/config --authorization-kubeconfig=/kube/config"
ccm_net="--network $network -v $work/kube:/kube:ro -v $work/cfg:/cfg:ro"

# shellcheck disable=SC2086
expect_fail missing-cloud-config "Couldn't open cloud provider configuration /cfg/missing.conf" \
  $ccm_net "$image" $ccm_args --cloud-config=/cfg/missing.conf
# shellcheck disable=SC2086
expect_fail garbage-cloud-config 'unable to read AWS cloud provider config file' \
  $ccm_net "$image" $ccm_args --cloud-config=/cfg/garbage.conf
# shellcheck disable=SC2086
expect_fail bad-zone 'invalid AZ: not-a-zone' \
  $ccm_net "$image" $ccm_args --cloud-config=/cfg/badzone.conf
# shellcheck disable=SC2086
expect_fail bad-override 'unable to validate custom endpoint overrides' \
  $ccm_net "$image" $ccm_args --cloud-config=/cfg/badoverride.conf
# Without a zone the provider asks the EC2 metadata service for its region; the
# internal network has no route to it, so initialization must fail, not hang.
# shellcheck disable=SC2086
expect_fail no-metadata 'Cloud provider could not be initialized' \
  $ccm_net "$image" $ccm_args
# shellcheck disable=SC2086
expect_fail wrong-provider 'unknown cloud provider gce' \
  $ccm_net "$image" --kubeconfig=/kube/config --cloud-provider=gce --cloud-config=/cfg/valid.conf

# Static placeholder credentials keep the SDK from probing for any other source.
# shellcheck disable=SC2086
docker run -d --label "$label" --name "$ccm" $ccm_net --read-only --cap-drop=ALL \
  -e AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE -e AWS_SECRET_ACCESS_KEY=verity-smoke-placeholder \
  "$image" $ccm_args --cloud-config=/cfg/valid.conf >/dev/null || fail 'ccm did not start'

probe() {
  docker run --rm --label "$label" --network "$network" "$curl_image" -sk --max-time 10 \
    -H "Authorization: Bearer $token" -o /dev/stdout -w '\n%{http_code}' "https://$ccm:10258$1" 2>/dev/null || true
}

healthz=
i=0
while [ "$i" -lt 45 ]; do
  [ "$(docker inspect -f '{{.State.Running}}' "$ccm" 2>/dev/null)" = true ] ||
    fail "ccm exited $(docker inspect -f '{{.State.ExitCode}}' "$ccm" 2>/dev/null)"
  healthz=$(probe /healthz)
  [ "$(code_of "$healthz")" = 200 ] && break
  i=$((i + 1))
  sleep 2
done
[ "$(code_of "$healthz")" = 200 ] || fail "healthz did not return 200: $healthz"
[ "$(body_of "$healthz")" = ok ] || fail "unexpected healthz body: $healthz"

metrics=$(probe /metrics)
[ "$(code_of "$metrics")" = 200 ] || fail "metrics did not return 200"
printf '%s\n' "$metrics" | grep -q "^kubernetes_build_info{.*git_version=\"v${expected_version}\"" ||
  fail 'metrics are missing kubernetes_build_info for this version'

anonymous=$(docker run --rm --label "$label" --network "$network" "$curl_image" -sk --max-time 10 \
  -o /dev/null -w '%{http_code}' "https://$ccm:10258/metrics" 2>/dev/null || true)
case $anonymous in
  401 | 403) ;;
  *) fail "anonymous /metrics returned $anonymous, expected 401 or 403" ;;
esac

docker logs "$ccm" 2>&1 | grep -q 'Version: v'"${expected_version}" ||
  fail 'ccm did not log its version at startup'

# Leader election is on by default; the lease must name this instance.
holder=
i=0
while [ "$i" -lt 30 ]; do
  lease=$(kube GET /apis/coordination.k8s.io/v1/namespaces/kube-system/leases/cloud-controller-manager)
  if [ "$(code_of "$lease")" = 200 ]; then
    holder=$(body_of "$lease" | jq -r '.spec.holderIdentity // empty')
    [ -n "$holder" ] && break
  fi
  i=$((i + 1))
  sleep 2
done
case $holder in
  "$(docker inspect -f '{{.Config.Hostname}}' "$ccm")"_*) ;;
  *) fail "leader lease holder is '$holder'" ;;
esac

# A LoadBalancer Service reaches the AWS provider: the service controller adds
# its cleanup finalizer and records the provider's failure to reach AWS.
created=$(kube POST /api/v1/namespaces/default/services '{"apiVersion":"v1","kind":"Service",
  "metadata":{"name":"verity-lb"},"spec":{"type":"LoadBalancer",
  "selector":{"app":"verity"},"ports":[{"port":80,"targetPort":8080}]}}')
[ "$(code_of "$created")" = 201 ] || fail "could not create the LoadBalancer Service: $created"

finalized=
failed=
i=0
while [ "$i" -lt 60 ]; do
  [ "$(docker inspect -f '{{.State.Running}}' "$ccm" 2>/dev/null)" = true ] ||
    fail "ccm exited $(docker inspect -f '{{.State.ExitCode}}' "$ccm" 2>/dev/null)"
  svc=$(kube GET /api/v1/namespaces/default/services/verity-lb)
  body_of "$svc" | jq -e '.metadata.finalizers // [] | index("service.kubernetes.io/load-balancer-cleanup")' \
    >/dev/null 2>&1 && finalized=yes
  events=$(kube GET '/api/v1/namespaces/default/events?fieldSelector=involvedObject.name%3Dverity-lb')
  failed=$(body_of "$events" | jq -r '.items[]? | select(.reason == "SyncLoadBalancerFailed") | .message' 2>/dev/null | head -n 1)
  [ -n "$finalized" ] && [ -n "$failed" ] && break
  i=$((i + 1))
  sleep 2
done
[ -n "$finalized" ] || fail 'the service controller did not add the load-balancer cleanup finalizer'
[ -n "$failed" ] || fail 'no SyncLoadBalancerFailed event for the LoadBalancer Service'
printf '%s\n' "$failed" | grep -qE 'operation error (EC2|Elastic Load Balancing)' ||
  fail "SyncLoadBalancerFailed did not come from an AWS API call: $failed"

# Upstream main.go runs the manager with wait.NeverStop, so it has no graceful
# shutdown: SIGTERM must terminate it at once (143), not after the 20s grace
# period (137) and not through a panic.
docker stop -t 20 "$ccm" >/dev/null
code=$(docker inspect -f '{{.State.ExitCode}}' "$ccm")
docker logs "$ccm" >"$work/shutdown.log" 2>&1
if grep -qE '^(panic: |fatal error: )' "$work/shutdown.log"; then
  fail "ccm panicked on SIGTERM: $(grep -E '^(panic: |fatal error: )' "$work/shutdown.log" | head -n 1)"
fi
case $code in
  0 | 143) ;;
  137) fail 'ccm ignored SIGTERM for 20s' ;;
  *) fail "ccm exited $code on SIGTERM" ;;
esac

printf 'SMOKE PASS version=%s\n' "$expected_version"
