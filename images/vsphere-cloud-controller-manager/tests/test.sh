#!/bin/sh
set -eu

# Out-of-cluster behavior that needs no vSphere. A pinned Verity etcd and
# kube-apiserver provide a real API server on a per-test bridge network. The cloud
# controller manager must:
#   - report its version and fail fast on unknown flags;
#   - fail fast without a kubeconfig, without a cloud config, and on invalid,
#     unreadable, or vCenter-less cloud configs;
#   - serve /healthz and /metrics on its secure port against the local API
#     server when it runs only the cloud-node-lifecycle controller, whose
#     vCenter lookups fail later without affecting the serving endpoints.

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

etcd_index=ghcr.io/tektum/etcd@sha256:fc322841b20ac374159333e013fb417aa712e776380c53dc34ab8a1958c07fd2
api_index=ghcr.io/tektum/kube-apiserver@sha256:b46742424f608bb186b83390c41cbe7f97df411ae3cf8fc3e4578c096a6b57bd
curl_index='docker.io/curlimages/curl:8.14.1@sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b'

id=$$
label="verity-test=vsphere-ccm-$id"
network="verity-vccm-$id"
etcd="verity-vccm-etcd-$id"
api="verity-vccm-api-$id"
ccm="verity-vccm-ccm-$id"
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
  '["/usr/bin/vsphere-cloud-controller-manager"]' ] || fail 'unexpected entrypoint'

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
[ "$(cat "$work/version.out")" = "vsphere-cloud-controller-manager v${expected_version}" ] ||
  fail "unexpected version: $(cat "$work/version.out")"

expect_fail unknown-flag 'unknown flag: --no-such-flag' --network none "$image" --no-such-flag
expect_fail no-kubeconfig 'invalid configuration: no configuration has been provided' \
  --network none "$image" --cloud-provider=vsphere

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

# Cloud configs. The vCenter address is reserved TEST-NET-1 and never reached.
cat >"$work/cfg/valid.yaml" <<'EOF'
global:
  port: 443
  insecureFlag: true
  user: verity
  password: verity
vcenter:
  smoke:
    server: 192.0.2.10
    datacenters:
      - dc1
EOF
printf 'global:\n  port: 443\n' >"$work/cfg/novcenter.yaml"
printf '[Global]\nthis is not ini or yaml = [\n' >"$work/cfg/garbage.conf"
chmod -R a+rX "$work"

docker network create --label "$label" "$network" >/dev/null
docker run -d --label "$label" --name "$etcd" --network "$network" \
  --tmpfs /var/lib/etcd:uid=65532,gid=65532 "$etcd_image" --data-dir=/var/lib/etcd/data \
  --listen-client-urls=http://0.0.0.0:2379 --advertise-client-urls="http://$etcd:2379" >/dev/null ||
  fail 'etcd did not start'
docker run -d --label "$label" --name "$api" --network "$network" --tmpfs /tmp:uid=65532,gid=65532 \
  -v "$work/pki:/pki:ro" "$api_image" \
  --etcd-servers="http://$etcd:2379" --secure-port=6443 --cert-dir=/tmp \
  --token-auth-file=/pki/tokens.csv --authorization-mode=RBAC \
  --service-account-issuer=https://kubernetes.default.svc \
  --service-account-key-file=/pki/sa.key --service-account-signing-key-file=/pki/sa.key \
  --service-cluster-ip-range=10.96.0.0/16 >/dev/null || fail 'kube-apiserver did not start'

i=0
until docker run --rm --label "$label" --network "$network" "$curl_image" -skf \
  -H "Authorization: Bearer $token" "https://$api:6443/readyz" >/dev/null 2>&1; do
  [ "$(docker inspect -f '{{.State.Running}}' "$api" 2>/dev/null)" = true ] ||
    fail 'kube-apiserver exited before it was ready'
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'kube-apiserver did not become ready'
  sleep 2
done

ccm_args="--kubeconfig=/kube/config --authentication-kubeconfig=/kube/config
  --authorization-kubeconfig=/kube/config --cloud-provider=vsphere --leader-elect=false
  --cert-dir=/tmp --secure-port=10258"

# Without --cloud-config, upstream v1.37's provider factory reads a nil reader and
# panics in vsphere.init (Go exit status 2). It still fails fast without serving.
# shellcheck disable=SC2086
expect_fail no-cloud-config 'pkg/cloudprovider/vsphere.init' --network "$network" --tmpfs /tmp:uid=65532,gid=65532 \
  -v "$work/kube:/kube:ro" "$image" $ccm_args
# shellcheck disable=SC2086
expect_fail missing-cloud-config "Couldn't open cloud provider configuration /cfg/missing.yaml" --network "$network" \
  --tmpfs /tmp:uid=65532,gid=65532 -v "$work/kube:/kube:ro" "$image" $ccm_args \
  --cloud-config=/cfg/missing.yaml
# shellcheck disable=SC2086
expect_fail garbage-cloud-config 'Cloud provider could not be initialized' --network "$network" \
  --tmpfs /tmp:uid=65532,gid=65532 -v "$work/kube:/kube:ro" -v "$work/cfg:/cfg:ro" "$image" \
  $ccm_args --cloud-config=/cfg/garbage.conf
# shellcheck disable=SC2086
expect_fail no-vcenter 'Cloud provider could not be initialized' --network "$network" \
  --tmpfs /tmp:uid=65532,gid=65532 -v "$work/kube:/kube:ro" -v "$work/cfg:/cfg:ro" "$image" \
  $ccm_args --cloud-config=/cfg/novcenter.yaml

# shellcheck disable=SC2086
docker run -d --label "$label" --name "$ccm" --network "$network" --read-only --cap-drop=ALL \
  --tmpfs /tmp:uid=65532,gid=65532 -v "$work/kube:/kube:ro" -v "$work/cfg:/cfg:ro" "$image" \
  $ccm_args --cloud-config=/cfg/valid.yaml --controllers=cloud-node-lifecycle >/dev/null ||
  fail 'ccm did not start'

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
  [ "$(printf '%s\n' "$healthz" | tail -n 1)" = 200 ] && break
  i=$((i + 1))
  sleep 2
done
[ "$(printf '%s\n' "$healthz" | tail -n 1)" = 200 ] || fail "healthz did not return 200: $healthz"
[ "$(printf '%s\n' "$healthz" | head -n 1)" = ok ] || fail "unexpected healthz body: $healthz"

metrics=$(probe /metrics)
[ "$(printf '%s\n' "$metrics" | tail -n 1)" = 200 ] || fail "metrics did not return 200"
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

docker stop -t 20 "$ccm" >/dev/null
code=$(docker inspect -f '{{.State.ExitCode}}' "$ccm")
docker logs "$ccm" >"$work/shutdown.log" 2>&1
grep -qF 'Stopped listening on [::]:10258' "$work/shutdown.log" ||
  fail 'ccm did not stop its secure server on SIGTERM'
# Upstream main.go watches the cloud config; when that watcher's channel closes
# during shutdown it may win the race and exit through klog.Fatal (255). Accept
# that path only with its exact log line. 137 means it ignored SIGTERM for 20s.
case $code in
  0 | 2 | 143) ;;
  255)
    grep -qF 'restarting pod because received event' "$work/shutdown.log" ||
      fail 'ccm exited 255 on SIGTERM without the config-watcher shutdown path'
    ;;
  *) fail "ccm exited $code on SIGTERM" ;;
esac

printf 'SMOKE PASS version=%s\n' "$expected_version"
