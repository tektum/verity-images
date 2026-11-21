#!/bin/sh
set -eu

# Offline behavior test for the CSI external-provisioner sidecar. Every
# sidecar runs with --network none against a kubeconfig that points at a
# closed loopback port, so the Kubernetes API is unreachable by design. The
# CSI side is real: a pinned upstream CSI hostpath driver serves the CSI
# Identity and Controller services on a Unix socket in a shared volume.
#
# 1. Without a socket the sidecar keeps dialing the --csi-address and reports
#    "Still connecting" instead of exiting.
# 2. With the driver up it probes it, discovers the driver name over gRPC,
#    reads its capabilities (PUBLISH_UNPUBLISH_VOLUME) and starts informers
#    against the (unreachable) API server while it keeps running.
# 3. --http-endpoint serves Prometheus metrics for those CSI calls and the
#    leader-election health check, read from the sidecar's own loopback.
# 4. Settings validated only after the CSI handshake are enforced.
# 5. SIGTERM stops PID 1 promptly and without a crash.

image=${1:?usage: test.sh IMAGE}
recipe="$(dirname "$0")/../melange.yaml"
expected_version=$(sed -n 's/^  version: "\([0-9][0-9.]*\)".*$/v\1/p' "$recipe")
driver_index='registry.k8s.io/sig-storage/hostpathplugin:v1.17.0@sha256:e20e2681349cb892bc88d8ab23c6785949bdb7e9b518bf3a261b5f13034f8b3b'
helper_index='docker.io/curlimages/curl:8.14.1@sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b'
label="verity-test=csi-provisioner-$$"
volume=verity-csi-provisioner-$$
driver=verity-csi-driver-$$
waiting=verity-csi-waiting-$$
sidecar=verity-csi-provisioner-$$
leader=verity-csi-leader-$$
nocapns=verity-csi-nocapns-$$
socket=/csi/csi.sock
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

[ -n "$expected_version" ] || fail 'csi-provisioner package version not found'

inspect() {
  docker image inspect --format "$1" "$image"
}

# Upstream Dockerfile: FROM distroless/static (root), ENTRYPOINT ["/csi-provisioner"].
[ "$(inspect '{{.Config.User}}')" = 0 ] || fail "unexpected OCI user: $(inspect '{{.Config.User}}')"
[ "$(inspect '{{json .Config.Entrypoint}}')" = '["/csi-provisioner"]' ] ||
  fail "unexpected entrypoint: $(inspect '{{json .Config.Entrypoint}}')"

version=$(docker run --rm --network none "$image" --version) || fail '--version failed'
[ "$version" = "/csi-provisioner $expected_version" ] ||
  fail "unexpected --version output: $version (want /csi-provisioner $expected_version)"

usage=$(docker run --rm --network none "$image" -h 2>&1 || true)
for flag in csi-address kubeconfig volume-name-prefix leader-election timeout http-endpoint enable-capacity; do
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

expect_exit 'unknown flag' 2 'unknown flag: --no-such-flag' --no-such-flag
expect_exit 'bad timeout' 2 'invalid argument "forever" for "--timeout" flag' --timeout=forever
expect_exit 'two metrics endpoints' 1 "only one of \`--metrics-address\` and \`--http-endpoint\` can be set." \
  --metrics-address=:8080 --http-endpoint=:8081
expect_exit 'node deployment without NODE_NAME' 255 \
  'The NODE_NAME environment variable must be set when using --enable-node-deployment.' \
  --node-deployment
expect_exit 'no cluster config' 255 'unable to load in-cluster configuration' \
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

# run_sidecar NAME ARGS...: start the sidecar detached against the shared volume.
run_sidecar() {
  name=$1
  shift
  docker run -d --label "$label" --name "$name" --network none -v "$volume:/csi" "$image" \
    --kubeconfig=/csi/kubeconfig --csi-address="$socket" --timeout=5s "$@" >/dev/null ||
    fail "$name did not start"
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

# fetch NAME PATH: GET PATH from the sidecar's --http-endpoint over its own loopback.
fetch() {
  docker run --rm --label "$label" --network "container:$1" "$helper_image" \
    -fsS --max-time 10 "http://127.0.0.1:8080$2"
}

# 1. No CSI socket yet: the sidecar must keep dialing the unix socket.
run_sidecar "$waiting" -v=5
wait_log "$waiting" 'Still connecting' 30
docker logs "$waiting" 2>&1 | grep 'Still connecting' | grep -qF "$socket" ||
  fail 'Still connecting does not name the --csi-address socket'
running "$waiting" || { show_logs "$waiting"; fail 'sidecar exited while waiting for the socket'; }
docker rm -f "$waiting" >/dev/null

# 2. Real CSI driver: probe, driver discovery, capabilities and informers.
docker run -d --label "$label" --name "$driver" --network none --user 65532 \
  -v "$volume:/csi" "$driver_image" \
  --endpoint="unix://$socket" --nodeid=verity --drivername="$driver_name" \
  --statedir=/csi/state --enable-attach=true >/dev/null || fail 'CSI driver did not start'

run_sidecar "$sidecar" -v=2 --http-endpoint=127.0.0.1:8080
wait_log "$sidecar" "Detected CSI driver $driver_name" 60
wait_log "$sidecar" 'CSI driver supports PUBLISH_UNPUBLISH_VOLUME, watching VolumeAttachments' 30
wait_log "$sidecar" 'ServeMux listening at "127.0.0.1:8080"' 30
wait_log "$sidecar" 'type="*v1.PersistentVolumeClaim"' 60
docker logs "$sidecar" 2>&1 | grep -F 'type="*v1.PersistentVolumeClaim"' |
  grep -qF 'https://127.0.0.1:6443/' || fail 'PersistentVolumeClaim watch did not use the kubeconfig server'
sleep 3
running "$sidecar" || { show_logs "$sidecar"; fail 'sidecar exited with the driver up'; }

# 3. Metrics record the real CSI calls. Probe and GetPluginInfo run before the
# driver name is known; the capability calls carry the discovered name.
metrics=$(fetch "$sidecar" /metrics) || { show_logs "$sidecar"; fail 'GET /metrics failed'; }
# has_call DRIVER METHOD: metrics hold an OK call of METHOD labelled DRIVER.
has_call() {
  printf '%s\n' "$metrics" | grep '^csi_sidecar_operations_seconds_count{' |
    grep -F "driver_name=\"$1\"" | grep -F "method_name=\"/csi.v1.$2\"" |
    grep -qF 'grpc_status_code="OK"' || fail "metrics lack an OK $2 call for $1"
}
has_call unknown-driver Identity/Probe
has_call unknown-driver Identity/GetPluginInfo
has_call "$driver_name" Identity/GetPluginCapabilities
has_call "$driver_name" Controller/ControllerGetCapabilities

# Leader election cannot reach the API server; the sidecar must keep serving
# its health check and stay a follower instead of exiting.
run_sidecar "$leader" --leader-election --http-endpoint=127.0.0.1:8080
wait_log "$leader" '"Attempting to acquire leader lease..." lock="default/hostpath-csi-k8s-io"' 60
wait_log "$leader" 'leases/hostpath-csi-k8s-io' 30
health=$(fetch "$leader" /healthz/leader-election) || { show_logs "$leader"; fail 'leader-election health check failed'; }
[ "$health" = ok ] || fail "unexpected leader-election health: $health"
running "$leader" || { show_logs "$leader"; fail 'sidecar exited during leader election'; }
if docker logs "$leader" 2>&1 | grep -qF 'successfully acquired lease'; then
  fail 'acquired a lease without an API server'
fi
docker rm -f "$leader" >/dev/null

# 4. Validation that only runs after a successful CSI handshake.
run_sidecar "$nocapns" --enable-capacity
status=$(timeout 60 docker wait "$nocapns") ||
  { show_logs "$nocapns"; fail 'capacity without NAMESPACE: sidecar did not exit within 60s'; }
[ "$status" = 255 ] || { show_logs "$nocapns"; fail "capacity without NAMESPACE: exit status $status, want 255"; }
docker logs "$nocapns" 2>&1 | grep -qF 'need NAMESPACE env variable for CSIStorageCapacity objects' ||
  { show_logs "$nocapns"; fail 'capacity without NAMESPACE error missing'; }
docker logs "$nocapns" 2>&1 | grep -qF 'CSI driver supports PUBLISH_UNPUBLISH_VOLUME' ||
  { show_logs "$nocapns"; fail 'capacity check ran before driver discovery'; }

# 5. SIGTERM must stop PID 1 well inside the grace period instead of waiting
# for SIGKILL (137). The Go runtime exits 143, or 2 when the kernel ignores the
# re-raised signal for a namespace init; which one depends on the host.
docker stop -t 30 "$sidecar" >/dev/null || fail 'docker stop failed'
code=$(docker inspect -f '{{.State.ExitCode}}' "$sidecar")
case "$code" in
  2 | 143) ;;
  *) show_logs "$sidecar"; fail "unexpected csi-provisioner exit code after SIGTERM: $code" ;;
esac
# Exit 2 is also the Go runtime's status for a panic or fatal error, so only
# accept it when the log shows no crash.
shutdown_log=$(docker logs "$sidecar" 2>&1) || fail 'could not read the csi-provisioner log after SIGTERM'
if printf '%s\n' "$shutdown_log" | grep -Eq '^(panic: |fatal error: |goroutine [0-9]+ \[)'; then
  printf '%s\n' "$shutdown_log" | tail -n 40 >&2
  fail 'csi-provisioner crashed (Go panic or fatal error) instead of stopping on SIGTERM'
fi

printf 'SMOKE PASS version=%s\n' "$expected_version"
