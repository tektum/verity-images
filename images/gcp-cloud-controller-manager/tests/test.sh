#!/bin/sh
set -eu

# Out-of-cluster behavior that needs no Google Cloud project. A pinned Verity
# etcd and kube-apiserver provide a real API server on a per-test internal
# bridge network, which has no route to the GCE metadata server or Google APIs.
# The cloud controller manager must:
#   - report its version, print help with the GCE flag set, and fail fast on
#     unknown flags, on an empty --cloud-provider, and without a kubeconfig;
#   - fail fast with --cloud-provider=gce when the cloud config is absent (the
#     provider falls back to the unreachable metadata server), missing,
#     unparsable, or valid but without credentials, and on an invalid GCE flag
#     combination;
#   - with a valid cloud config and syntactically valid application default
#     credentials, serve /healthz and /metrics on its secure port and run the
#     cloud-node-lifecycle controller, which resolves a node's GCE providerID
#     into a Compute API instance lookup that fails only for lack of a token.

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

etcd_index=ghcr.io/tektum/etcd@sha256:fc322841b20ac374159333e013fb417aa712e776380c53dc34ab8a1958c07fd2
api_index=ghcr.io/tektum/kube-apiserver@sha256:b46742424f608bb186b83390c41cbe7f97df411ae3cf8fc3e4578c096a6b57bd
curl_index='docker.io/curlimages/curl:8.14.1@sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b'

id=$$
label="verity-test=gcp-ccm-$id"
network="verity-gccm-$id"
etcd="verity-gccm-etcd-$id"
api="verity-gccm-api-$id"
ccm="verity-gccm-ccm-$id"
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  for c in "$ccm" "$api"; do
    printf -- '--- %s\n' "$c" >&2
    docker logs "$c" 2>&1 | grep -v 'extension-apiserver-authentication' | tail -n 30 >&2 || true
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
expected_commit=$(awk '$1 == "source-commit:" { print $2; exit }' "$here/../melange.yaml")
[ -n "$expected_commit" ] || fail 'could not read the recipe source commit'

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] ||
  fail 'unexpected OCI user'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/cloud-controller-manager"]' ] || fail 'unexpected entrypoint'

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
[ "$(cat "$work/version.out")" = "cloud-controller-manager v${expected_version}" ] ||
  fail "unexpected version: $(cat "$work/version.out")"

out version-raw --network none "$image" --version=raw
[ "$status" = 0 ] || fail "version=raw exited $status"
for field in "GitVersion:\"v${expected_version}\"" "GitCommit:\"${expected_commit}\"" \
  "Major:\"${expected_version%%.*}\""; do
  grep -qF "$field" "$work/version-raw.out" || fail "version=raw is missing $field"
done

# Upstream's image runs /cloud-controller-manager; manifests that override the
# command keep working through the compatibility link.
out legacy-path --network none --entrypoint /cloud-controller-manager "$image" --version
[ "$status" = 0 ] || fail "/cloud-controller-manager exited $status"
[ "$(cat "$work/legacy-path.out")" = "cloud-controller-manager v${expected_version}" ] ||
  fail "unexpected /cloud-controller-manager version: $(cat "$work/legacy-path.out")"

out help --network none "$image" --help
[ "$status" = 0 ] || fail "help exited $status"
for text in 'GCE Cloud Provider flags:' '--cloud-config string' '--enable-l4-deny-firewall' \
  'Nodeipam controller flags:'; do
  grep -qF -- "$text" "$work/help.out" || fail "help is missing '$text'"
done

expect_fail unknown-flag 'unknown flag: --no-such-flag' --network none "$image" --no-such-flag
expect_fail no-provider '--cloud-provider cannot be empty' --network none "$image"
expect_fail no-kubeconfig 'invalid configuration: no configuration has been provided' \
  --network none "$image" --cloud-provider=gce

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

# GCE cloud configs (gcfg). project-id, local-zone, and network-name replace
# every metadata server lookup the provider makes at startup.
cat >"$work/cfg/valid.conf" <<'EOF'
[global]
project-id = verity-smoke
local-zone = us-central1-a
network-name = default
node-tags = verity-smoke-node
EOF
printf '[global\nproject-id = verity-smoke\n' >"$work/cfg/garbage.conf"
# Application default credentials are required to construct the provider's
# Google API clients. They are never exchanged: no token endpoint is reachable.
cat >"$work/cfg/adc.json" <<'EOF'
{"type": "authorized_user", "client_id": "verity-smoke.apps.googleusercontent.com",
 "client_secret": "verity-smoke", "refresh_token": "verity-smoke"}
EOF
chmod -R a+rX "$work"

# An internal network has no default route, so kube-apiserver needs an explicit
# advertise address; a TEST-NET-1 address is only published, never dialed here.
docker network create --internal --label "$label" "$network" >/dev/null
docker run -d --label "$label" --name "$etcd" --network "$network" \
  --tmpfs /var/lib/etcd:uid=65532,gid=65532 "$etcd_image" --data-dir=/var/lib/etcd/data \
  --listen-client-urls=http://0.0.0.0:2379 --advertise-client-urls="http://$etcd:2379" >/dev/null ||
  fail 'etcd did not start'
docker run -d --label "$label" --name "$api" --network "$network" --tmpfs /tmp:uid=65532,gid=65532 \
  -v "$work/pki:/pki:ro" "$api_image" \
  --etcd-servers="http://$etcd:2379" --secure-port=6443 --cert-dir=/tmp \
  --advertise-address=192.0.2.1 \
  --token-auth-file=/pki/tokens.csv --authorization-mode=RBAC \
  --service-account-issuer=https://kubernetes.default.svc \
  --service-account-key-file=/pki/sa.key --service-account-signing-key-file=/pki/sa.key \
  --service-cluster-ip-range=10.96.0.0/16 >/dev/null || fail 'kube-apiserver did not start'

# kapi METHOD PATH [CONTENT_TYPE BODY]: call kube-apiserver; print the HTTP status.
kapi() {
  if [ "$#" -gt 2 ]; then
    docker run --rm --label "$label" --network "$network" "$curl_image" -sk --max-time 10 \
      -H "Authorization: Bearer $token" -H "Content-Type: $3" -X "$1" -d "$4" \
      -o /dev/null -w '%{http_code}' "https://$api:6443$2" 2>/dev/null || true
  else
    docker run --rm --label "$label" --network "$network" "$curl_image" -sk --max-time 10 \
      -H "Authorization: Bearer $token" -X "$1" \
      -o /dev/null -w '%{http_code}' "https://$api:6443$2" 2>/dev/null || true
  fi
}

i=0
until [ "$(kapi GET /readyz)" = 200 ]; do
  [ "$(docker inspect -f '{{.State.Running}}' "$api" 2>/dev/null)" = true ] ||
    fail 'kube-apiserver exited before it was ready'
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'kube-apiserver did not become ready'
  sleep 2
done

ccm_args="--kubeconfig=/kube/config --authentication-kubeconfig=/kube/config
  --authorization-kubeconfig=/kube/config --cloud-provider=gce --leader-elect=false
  --cert-dir=/tmp --secure-port=10258"
ccm_mounts="--tmpfs /tmp:uid=65532,gid=65532 -v $work/kube:/kube:ro -v $work/cfg:/cfg:ro"

# shellcheck disable=SC2086
expect_fail no-cloud-config 'computeMetadata/v1/instance/zone' --network "$network" \
  $ccm_mounts "$image" $ccm_args
# shellcheck disable=SC2086
expect_fail missing-cloud-config "Couldn't open cloud provider configuration /cfg/missing.conf" \
  --network "$network" $ccm_mounts "$image" $ccm_args --cloud-config=/cfg/missing.conf
# shellcheck disable=SC2086
expect_fail garbage-cloud-config 'expected subsection name or right bracket' --network "$network" \
  $ccm_mounts "$image" $ccm_args --cloud-config=/cfg/garbage.conf
# shellcheck disable=SC2086
expect_fail no-credentials 'could not find default credentials' --network "$network" \
  $ccm_mounts "$image" $ccm_args --cloud-config=/cfg/valid.conf
# shellcheck disable=SC2086
expect_fail deny-firewall-flags \
  'enable-l4-deny-firewall requires enable-l4-deny-firewall-rollback-cleanup to be true' \
  --network "$network" $ccm_mounts -e GOOGLE_APPLICATION_CREDENTIALS=/cfg/adc.json "$image" \
  $ccm_args --cloud-config=/cfg/valid.conf --enable-l4-deny-firewall

# A NotReady node with a GCE providerID gives cloud-node-lifecycle work to do.
node=verity-node-1
code=$(kapi POST /api/v1/nodes application/json \
  "{\"apiVersion\":\"v1\",\"kind\":\"Node\",\"metadata\":{\"name\":\"$node\"},
    \"spec\":{\"providerID\":\"gce://verity-smoke/us-central1-a/$node\"}}")
[ "$code" = 201 ] || fail "could not create node $node: HTTP $code"
code=$(kapi PATCH "/api/v1/nodes/$node/status" application/merge-patch+json \
  '{"status":{"conditions":[{"type":"Ready","status":"False","reason":"KubeletStopped",
    "message":"smoke","lastHeartbeatTime":"2026-01-01T00:00:00Z",
    "lastTransitionTime":"2026-01-01T00:00:00Z"}]}}')
[ "$code" = 200 ] || fail "could not mark node $node NotReady: HTTP $code"

# shellcheck disable=SC2086
docker run -d --label "$label" --name "$ccm" --network "$network" --read-only --cap-drop=ALL \
  $ccm_mounts -e GOOGLE_APPLICATION_CREDENTIALS=/cfg/adc.json "$image" \
  $ccm_args --cloud-config=/cfg/valid.conf --controllers=cloud-node-lifecycle >/dev/null ||
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
printf '%s\n' "$metrics" |
  grep -q "^kubernetes_build_info{.*git_commit=\"${expected_commit}\".*git_version=\"v${expected_version}\"" ||
  fail 'metrics are missing kubernetes_build_info for this version and commit'

anonymous=$(docker run --rm --label "$label" --network "$network" "$curl_image" -sk --max-time 10 \
  -o /dev/null -w '%{http_code}' "https://$ccm:10258/metrics" 2>/dev/null || true)
case $anonymous in
  401 | 403) ;;
  *) fail "anonymous /metrics returned $anonymous, expected 401 or 403" ;;
esac

docker logs "$ccm" 2>&1 | grep -q 'Version: v'"${expected_version}" ||
  fail 'ccm did not log its version at startup'
docker logs "$ccm" 2>&1 | grep -q 'Using GCE provider config .*ProjectID:verity-smoke .*LocalZone:us-central1-a' ||
  fail 'ccm did not log the parsed GCE cloud config'
docker logs "$ccm" 2>&1 | grep -qF 'Started "cloud-node-lifecycle-controller"' ||
  fail 'ccm did not start the cloud-node-lifecycle controller'

# The lifecycle controller asks the GCE provider whether the NotReady node's
# instance still exists; the Compute API URL proves the providerID was parsed.
lookup="error checking if node $node exists: Get \"https://compute.googleapis.com/compute/v1/projects/verity-smoke/zones/us-central1-a/instances/$node?"
i=0
until docker logs "$ccm" 2>&1 | grep -qF "$lookup"; do
  [ "$(docker inspect -f '{{.State.Running}}' "$ccm" 2>/dev/null)" = true ] ||
    fail "ccm exited $(docker inspect -f '{{.State.ExitCode}}' "$ccm" 2>/dev/null)"
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail 'cloud-node-lifecycle did not look up the node instance in GCE'
  sleep 2
done
[ "$(kapi GET "/api/v1/nodes/$node")" = 200 ] ||
  fail 'the node was deleted although its instance lookup failed'

# Upstream runs the controllers until the process is killed and installs no
# SIGTERM handler, so the default Go action (143) is the expected exit.
docker stop -t 20 "$ccm" >/dev/null
code=$(docker inspect -f '{{.State.ExitCode}}' "$ccm")
docker logs "$ccm" >"$work/shutdown.log" 2>&1
if grep -qE '^(panic: |fatal error: )' "$work/shutdown.log"; then
  fail "ccm panicked on SIGTERM: $(grep -E '^(panic: |fatal error: )' "$work/shutdown.log" | head -n 1)"
fi
case $code in
  0 | 143) ;;
  *) fail "ccm exited $code on SIGTERM" ;;
esac

printf 'SMOKE PASS version=%s\n' "$expected_version"
