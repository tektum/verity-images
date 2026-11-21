#!/bin/sh
set -eu

# Offline behavior test for the CSI external-resizer sidecar. Every sidecar
# runs with --network none against a kubeconfig that points at a closed
# loopback port, so the Kubernetes API is unreachable by design. The CSI side
# is real: pinned upstream CSI hostpath drivers serve the CSI Identity and
# Controller services on Unix sockets in a shared volume.
#
# 1. Without a socket the sidecar keeps dialing the --csi-address and reports
#    "Still connecting" instead of exiting.
# 2. With the default driver up it discovers the driver name over gRPC, reads
#    the EXPAND_VOLUME controller capability, builds the CSI resizer (not the
#    node-only trivial resizer) and starts its controller, which then lists
#    objects from the (unreachable) API server.
# 3. The capability check is real: a driver started with
#    --disable-controller-expansion gets the trivial resizer, and a driver
#    with no expansion at all makes the sidecar exit.

image=${1:?usage: test.sh IMAGE}
recipe="$(dirname "$0")/../melange.yaml"
expected_version=$(sed -n 's/^  version: "\([0-9][0-9.]*\)".*$/v\1/p' "$recipe")
driver_index='registry.k8s.io/sig-storage/hostpathplugin:v1.17.0@sha256:e20e2681349cb892bc88d8ab23c6785949bdb7e9b518bf3a261b5f13034f8b3b'
helper_index='docker.io/curlimages/curl:8.14.1@sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b'
label="verity-test=csi-resizer-$$"
volume=verity-csi-resizer-$$
driver=verity-csi-driver-$$
nodeonly_driver=verity-csi-nodeonly-driver-$$
noexpand_driver=verity-csi-noexpand-driver-$$
waiting=verity-csi-waiting-$$
sidecar=verity-csi-resizer-$$
nodeonly=verity-csi-nodeonly-$$
noexpand=verity-csi-noexpand-$$
socket=/csi/csi.sock
nodeonly_socket=/csi/nodeonly.sock
noexpand_socket=/csi/noexpand.sock
driver_name=hostpath.csi.k8s.io

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

show_logs() {
  docker logs "$1" 2>&1 | tail -n 40 >&2 || true
}

[ -n "$expected_version" ] || fail 'csi-resizer package version not found'

inspect() {
  docker image inspect --format "$1" "$image"
}

# Upstream Dockerfile: FROM distroless/static (root), ENTRYPOINT ["/csi-resizer"].
[ "$(inspect '{{.Config.User}}')" = 0 ] || fail "unexpected OCI user: $(inspect '{{.Config.User}}')"
[ "$(inspect '{{json .Config.Entrypoint}}')" = '["/csi-resizer"]' ] ||
  fail "unexpected entrypoint: $(inspect '{{json .Config.Entrypoint}}')"

version=$(docker run --rm --network none "$image" --version) || fail '--version failed'
[ "$version" = "/csi-resizer $expected_version" ] ||
  fail "unexpected --version output: $version (want /csi-resizer $expected_version)"

usage=$(docker run --rm --network none "$image" -h 2>&1 || true)
for flag in csi-address kubeconfig leader-election timeout resize-timeout feature-gates workers; do
  printf '%s\n' "$usage" | grep -q -- "-$flag" || fail "usage is missing -$flag"
done

# expect_exit NAME STATUS PATTERN ARGS...: the sidecar exits STATUS and logs PATTERN.
expect_exit() {
  name=$1 want=$2 pattern=$3
  shift 3
  status=0
  out=$(docker run --rm --network none "$image" "$@" 2>&1) || status=$?
  [ "$status" = "$want" ] || {
    printf '%s\n' "$out" >&2
    fail "$name: exit status $status, want $want"
  }
  printf '%s\n' "$out" | grep -qF -- "$pattern" || {
    printf '%s\n' "$out" >&2
    fail "$name: missing '$pattern'"
  }
}

expect_exit 'unknown flag' 2 'flag provided but not defined: -no-such-flag' --no-such-flag
expect_exit 'bad timeout' 2 'invalid value "forever" for flag -timeout' --timeout=forever
expect_exit 'malformed feature gate' 2 'malformed pair, expect string=bool' --feature-gates=x
expect_exit 'unknown feature gate' 1 'unrecognized feature gate: NoSuchGate' \
  --feature-gates=NoSuchGate=true
expect_exit 'metrics and http endpoint' 1 "Only one of \`--metrics-address\` and \`--http-endpoint\` can be set." \
  --metrics-address=:8080 --http-endpoint=:8081
expect_exit 'no cluster config' 1 'unable to load in-cluster configuration' \
  --csi-address="$socket"

# pull_child INDEX: pull the pinned index by its per-platform child digest, verifying the
# index bytes against the pin first. publish-image runs this test once per platform on one
# host, and a classic Docker image store cannot bind an index digest to a second platform.
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
driver_image=$(pull_child "$driver_index") || exit 1
helper_image=$(pull_child "$helper_index") || exit 1
[ -n "$driver_image" ] && [ -n "$helper_image" ] || fail 'cannot resolve helper images'

# The shared volume holds the CSI socket and a kubeconfig for an API server
# that cannot be reached from a container without a network.
docker volume create --label "$label" "$volume" >/dev/null
docker run --rm --label "$label" --network none -u 0 -v "$volume:/csi" --entrypoint sh "$helper_image" -c '
  chmod 0777 /csi
  cat > /csi/kubeconfig <<EOF
apiVersion: v1
kind: Config
clusters:
- name: offline
  cluster:
    server: https://127.0.0.1:6443
    insecure-skip-tls-verify: true
contexts:
- name: offline
  context:
    cluster: offline
    user: offline
current-context: offline
users:
- name: offline
  user:
    token: offline
EOF
  chmod 0644 /csi/kubeconfig' || fail 'could not prepare the shared volume'

# run_sidecar NAME SOCKET ARGS...: start the sidecar detached against the shared volume.
run_sidecar() {
  name=$1 address=$2
  shift 2
  docker run -d --label "$label" --name "$name" --network none -v "$volume:/csi" "$image" \
    --kubeconfig=/csi/kubeconfig --csi-address="$address" --timeout=5s "$@" >/dev/null ||
    fail "$name did not start"
}

# run_driver NAME SOCKET ARGS...: start a pinned CSI hostpath driver on SOCKET.
run_driver() {
  name=$1 address=$2
  shift 2
  docker run -d --label "$label" --name "$name" --network none --user 65532 \
    -v "$volume:/csi" "$driver_image" \
    --endpoint="unix://$address" --nodeid=verity --drivername="$driver_name" \
    --statedir="/csi/state-$name" "$@" >/dev/null || fail "$name did not start"
}

# wait_log NAME PATTERN SECONDS: wait until the container logs contain PATTERN.
wait_log() {
  i=0
  while [ "$i" -lt "$3" ]; do
    docker logs "$1" 2>&1 | grep -qF -- "$2" && return 0
    i=$((i + 1))
    sleep 1
  done
  show_logs "$1"
  fail "$1: no '$2' after $3s"
}

running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$1")" = true ]
}

# 1. No CSI socket yet: the sidecar must keep dialing the unix socket.
run_sidecar "$waiting" "$socket" -v=5
wait_log "$waiting" 'Still connecting' 30
docker logs "$waiting" 2>&1 | grep 'Still connecting' | grep -qF "$socket" ||
  fail 'Still connecting does not name the --csi-address socket'
running "$waiting" || { show_logs "$waiting"; fail 'sidecar exited while waiting for the socket'; }
docker rm -f "$waiting" >/dev/null

# 2. Real CSI driver: driver discovery, EXPAND_VOLUME capability and controller start.
run_driver "$driver" "$socket"
run_sidecar "$sidecar" "$socket" -v=5
wait_log "$sidecar" "\"CSI driver name\" driverName=\"$driver_name\"" 60
wait_log "$sidecar" "\"Starting external resizer\" controller=\"$driver_name\"" 30
sleep 3
running "$sidecar" || { show_logs "$sidecar"; fail 'sidecar exited with the driver up'; }
docker logs "$sidecar" 2>&1 | grep -F '"GRPC response"' | grep -qF '\"type\":\"EXPAND_VOLUME\"' ||
  { show_logs "$sidecar"; fail 'driver did not advertise the EXPAND_VOLUME controller capability'; }
if docker logs "$sidecar" 2>&1 | grep -qF -e 'using trivial resizer' -e 'Resize not supported'; then
  show_logs "$sidecar"
  fail 'sidecar did not build the controller CSI resizer'
fi
docker logs "$sidecar" 2>&1 | grep -qF '127.0.0.1:6443' ||
  { show_logs "$sidecar"; fail 'sidecar never tried the kubeconfig API server'; }

# 3. Capability gating. Without the controller capability the node-only
#    trivial resizer is used; without any expansion the sidecar must exit.
run_driver "$nodeonly_driver" "$nodeonly_socket" --disable-controller-expansion
run_sidecar "$nodeonly" "$nodeonly_socket"
wait_log "$nodeonly" 'The CSI driver supports node resize only, using trivial resizer' 60
wait_log "$nodeonly" "\"Starting external resizer\" controller=\"$driver_name\"" 30

run_driver "$noexpand_driver" "$noexpand_socket" --enable-volume-expansion=false
run_sidecar "$noexpand" "$noexpand_socket"
status=$(timeout 60 docker wait "$noexpand") ||
  { show_logs "$noexpand"; fail 'no expansion: sidecar did not exit within 60s'; }
[ "$status" = 255 ] || { show_logs "$noexpand"; fail "no expansion: exit status $status, want 255"; }
docker logs "$noexpand" 2>&1 | grep -qF 'CSI driver does not support resize nor modify' ||
  { show_logs "$noexpand"; fail 'no expansion error missing'; }

printf 'SMOKE PASS version=%s\n' "$expected_version"
