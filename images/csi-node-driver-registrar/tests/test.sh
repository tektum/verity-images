#!/bin/sh
set -eu

# A pinned upstream CSI hostpath driver serves the CSI Identity API on a Unix
# socket in a shared volume. The registrar under test must discover the driver
# name through it, create the kubelet plugin registration socket in a second
# volume, answer the kubelet plugin watcher's GetInfo and
# NotifyRegistrationStatus RPCs, and report the socket through /healthz on
# --http-endpoint. Every client is a pinned curl container on the shared
# volumes or in the registrar's network namespace; nothing reaches the network.

image=${1:?usage: test.sh IMAGE}
recipe="$(dirname "$0")/../melange.yaml"
expected_version=$(sed -n 's/^  version: "\([0-9][0-9.]*\)".*$/\1/p' "$recipe")
driver_index='registry.k8s.io/sig-storage/hostpathplugin:v1.17.0@sha256:e20e2681349cb892bc88d8ab23c6785949bdb7e9b518bf3a261b5f13034f8b3b'
curl_index='docker.io/curlimages/curl:8.14.1@sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b'
label="verity-test=csi-node-driver-registrar-$$"
csi_volume=verity-ndr-csi-$$
reg_volume=verity-ndr-reg-$$
driver=verity-ndr-driver-$$
driver_name=hostpath.csi.k8s.io
kubelet_socket=/var/lib/kubelet/plugins/csi-hostpath/csi.sock
reg_socket="/registration/$driver_name-reg.sock"
http_endpoint=127.0.0.1:9809

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker volume rm -f "$csi_volume" "$reg_volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ -n "$expected_version" ] || fail 'node-driver-registrar package version not found'

inspect() {
  docker image inspect --format "$1" "$image"
}

# Upstream image contract: distroless/static root user,
# ENTRYPOINT ["/csi-node-driver-registrar"].
[ "$(inspect '{{.Config.User}}')" = 0 ] || fail "unexpected OCI user: $(inspect '{{.Config.User}}')"
[ "$(inspect '{{json .Config.Entrypoint}}')" = '["/csi-node-driver-registrar"]' ] ||
  fail "unexpected entrypoint: $(inspect '{{json .Config.Entrypoint}}')"

version=$(docker run --rm --network none "$image" --version) || fail '--version failed'
[ "$version" = "/csi-node-driver-registrar v$expected_version" ] ||
  fail "unexpected version output: $version"

# run_fast NAME ARGS...: run a registrar that must exit on its own within
# $fast_limit seconds (default 30); prints its combined output and returns its
# exit status.
run_fast() {
  name=$1
  shift
  docker run -d --label "$label" --name "$name" "$@" >/dev/null || return 125
  i=0
  while [ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ]; do
    i=$((i + 1))
    [ $i -lt "${fast_limit:-30}" ] ||
      { docker logs "$name" >&2; printf '%s did not exit on its own\n' "$name" >&2; return 124; }
    sleep 1
  done
  docker logs "$name" 2>&1
  return "$(docker inspect -f '{{.State.ExitCode}}' "$name")"
}

# Negative: unknown flags are rejected by flag parsing (exit 2).
status=0
out=$(run_fast verity-ndr-badflag-$$ --network none "$image" --no-such-flag) || status=$?
[ "$status" = 2 ] || fail "unknown flag exited $status, want 2"
printf '%s\n' "$out" | grep -qF 'flag provided but not defined: -no-such-flag' ||
  fail 'unknown flag error is missing'

# Negative: --kubelet-registration-path is required, so the registrar must
# fail fast before it waits on any CSI socket.
status=0
out=$(run_fast verity-ndr-noreg-$$ --network none "$image" --csi-address=/csi/csi.sock) || status=$?
[ "$status" = 1 ] || fail "missing --kubelet-registration-path exited $status, want 1"
printf '%s\n' "$out" | grep -qF 'kubelet-registration-path is a required parameter' ||
  fail 'missing --kubelet-registration-path error is missing'

# Negative: the deprecated --health-port conflicts with --http-endpoint.
status=0
out=$(run_fast verity-ndr-conflict-$$ --network none "$image" \
  --kubelet-registration-path="$kubelet_socket" --health-port=9808 --http-endpoint=:9809) || status=$?
[ "$status" = 1 ] || fail "--health-port with --http-endpoint exited $status, want 1"
printf '%s\n' "$out" | grep -q 'Only one of .--health-port. and .--http-endpoint. can be set' ||
  fail '--health-port/--http-endpoint conflict error is missing'

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
curl_image=$(pull_child "$curl_index") || exit 1
[ -n "$driver_image" ] && [ -n "$curl_image" ] || fail 'cannot resolve helper images'

docker volume create --label "$label" "$csi_volume" >/dev/null
docker volume create --label "$label" "$reg_volume" >/dev/null
docker run --rm --label "$label" -u 0 -v "$csi_volume:/csi" --entrypoint chmod "$curl_image" 0777 /csi ||
  fail 'could not prepare the CSI socket volume'

# start_registrar NAME ARGS...: run the registrar against the shared volumes.
start_registrar() {
  name=$1
  shift
  docker run -d --label "$label" --name "$name" \
    -v "$csi_volume:/csi" -v "$reg_volume:/registration" "$image" \
    --csi-address=/csi/csi.sock --kubelet-registration-path="$kubelet_socket" \
    --http-endpoint="$http_endpoint" "$@" >/dev/null || fail "$name did not start"
}

running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" = true ]
}

# in_reg CMD...: run a shell command as root next to the registration socket.
in_reg() {
  docker run --rm --label "$label" -u 0 -v "$reg_volume:/registration" \
    --entrypoint sh "$curl_image" -c "$@"
}

# healthz NAME: print "<status> <body>" from the registrar's /healthz.
healthz() {
  docker run --rm --label "$label" --network "container:$1" "$curl_image" \
    -s -w ' %{http_code}' --max-time 10 "http://$http_endpoint/healthz" 2>/dev/null |
    awk '{ code = $NF; $NF = ""; sub(/ $/, ""); print code, $0 }' || true
}

wait_healthy() {
  i=0
  while [ $i -lt 60 ]; do
    [ "$(healthz "$1")" = '200 ok' ] && return 0
    running "$1" || break
    i=$((i + 1))
    sleep 1
  done
  docker logs "$1" >&2 || true
  fail "$1 /healthz did not report 200 ok with a live driver"
}

# grpc METHOD FRAME: unary pluginregistration.Registration call on the
# registration socket. FRAME is a printf format holding the 5-byte gRPC header
# and the protobuf request. Prints "status=<grpc-status>" and "body=<hex>".
grpc() {
  # shellcheck disable=SC2016 # expanded by the helper container's shell
  in_reg '
    printf "$2" | curl -sS --http2-prior-knowledge --unix-socket "$3" --max-time 5 \
      -H "content-type: application/grpc" -H "te: trailers" -D /tmp/h \
      --data-binary @- -o /tmp/b "http://localhost/pluginregistration.Registration/$1" || exit 1
    printf "status=%s\n" "$(tr -d "\r" < /tmp/h | sed -n "s/^grpc-status: *//Ip" | tail -n 1)"
    printf "body=%s\n" "$(od -An -tx1 -v /tmp/b | tr -d " \n")"
  ' sh "$1" "$2" "$reg_socket"
}

hex() {
  printf '%s' "$1" | od -An -tx1 -v | tr -d ' \n'
}

# field TAG STRING: protobuf length-delimited field (all values here are < 128 bytes).
field() {
  printf '%s%02x%s' "$1" "${#2}" "$(hex "$2")"
}

# Negative: without a CSI driver behind --csi-address the registrar retries,
# then gives up and exits 1 without creating a registration socket.
status=0
out=$(fast_limit=90 run_fast verity-ndr-nodriver-$$ --network none \
  -v "$csi_volume:/csi" -v "$reg_volume:/registration" "$image" \
  --csi-address=/csi/csi.sock --kubelet-registration-path="$kubelet_socket") || status=$?
[ "$status" = 1 ] || fail "missing CSI driver exited $status, want 1"
printf '%s\n' "$out" | grep -F 'Still connecting' | grep -qF '/csi/csi.sock' ||
  fail 'registrar did not report waiting for the CSI socket'
printf '%s\n' "$out" | grep -qF 'Error connecting to CSI driver' ||
  fail 'missing CSI driver error is missing'
in_reg "[ ! -e '$reg_socket' ]" || fail 'registration socket exists without a CSI driver'

docker run -d --label "$label" --name "$driver" --network none --user 65532 \
  -v "$csi_volume:/csi" "$driver_image" \
  --endpoint=unix:///csi/csi.sock --nodeid=verity --drivername="$driver_name" \
  --statedir=/csi/state >/dev/null || fail 'CSI driver did not start'

start_registrar verity-ndr-main-$$
wait_healthy verity-ndr-main-$$
docker logs verity-ndr-main-$$ 2>&1 | grep -qF "Version\" version=\"v$expected_version\"" ||
  fail 'registrar did not log its version'
docker logs verity-ndr-main-$$ 2>&1 | grep -qF "socketPath=\"$reg_socket\"" ||
  fail 'registrar did not report the registration socket path'

# The registration socket is owner-only (umask 0077) and owned by root.
mode=$(in_reg "stat -c '%F %a %u' '$reg_socket'") || fail 'cannot stat the registration socket'
[ "$mode" = 'socket 700 0' ] || fail "unexpected registration socket mode: $mode"

# kubelet plugin watcher GetInfo: type, discovered driver name, host endpoint, versions.
out=$(grpc GetInfo '\000\000\000\000\000') || fail 'GetInfo call failed'
printf '%s\n' "$out" | grep -qx 'status=0' || fail "GetInfo returned an error: $out"
msg="$(field 0a CSIPlugin)$(field 12 "$driver_name")$(field 1a "$kubelet_socket")$(field 22 1.0.0)"
expected="body=00$(printf '%08x' $((${#msg} / 2)))$msg"
printf '%s\n' "$out" | grep -qx "$expected" || fail "unexpected GetInfo response: $out"

# NotifyRegistrationStatus{plugin_registered: true} is acknowledged; the registrar stays up.
out=$(grpc NotifyRegistrationStatus '\000\000\000\000\002\010\001') ||
  fail 'NotifyRegistrationStatus call failed'
printf '%s\n' "$out" | grep -qx 'status=0' || fail "NotifyRegistrationStatus returned an error: $out"
printf '%s\n' "$out" | grep -qx 'body=0000000000' || fail "unexpected NotifyRegistrationStatus response: $out"
sleep 1
running verity-ndr-main-$$ || fail 'registrar exited after a successful registration'
docker logs verity-ndr-main-$$ 2>&1 | grep -qF 'Received NotifyRegistrationStatus call' ||
  fail 'registrar did not log the registration status'

# Negative: a CSI address that is not a CSI driver (the live registration
# socket) must fail fast on driver name discovery.
status=0
out=$(run_fast verity-ndr-notcsi-$$ --network none -v "$reg_volume:/peer:ro" "$image" \
  --csi-address="/peer/$driver_name-reg.sock" --kubelet-registration-path="$kubelet_socket") || status=$?
[ "$status" = 1 ] || fail "non-CSI --csi-address exited $status, want 1"
printf '%s\n' "$out" | grep -qF 'Error retreiving CSI driver name' ||
  fail 'non-CSI --csi-address error is missing'

# SIGTERM removes the registration socket and exits 0.
docker stop -t 10 verity-ndr-main-$$ >/dev/null || fail 'registrar did not stop'
[ "$(docker inspect -f '{{.State.ExitCode}}' verity-ndr-main-$$)" = 0 ] ||
  fail 'registrar did not exit 0 on SIGTERM'
in_reg "[ ! -e '$reg_socket' ]" || fail 'registration socket survived SIGTERM'

# Negative: /healthz reports 404 once the registration socket is gone.
start_registrar verity-ndr-gone-$$
wait_healthy verity-ndr-gone-$$
in_reg "rm '$reg_socket'" || fail 'cannot remove the registration socket'
status=$(healthz verity-ndr-gone-$$)
[ "$status" = '404 registration socket does not exist' ] ||
  fail "unexpected /healthz without a registration socket: $status"
docker rm -f verity-ndr-gone-$$ >/dev/null

# Negative: kubelet reporting a failed registration makes the registrar exit 1
# so the pod restarts it.
start_registrar verity-ndr-rejected-$$
wait_healthy verity-ndr-rejected-$$
# The registrar exits mid-call, so the client sees a broken stream.
grpc NotifyRegistrationStatus '\000\000\000\000\007\022\005smoke' >/dev/null 2>&1 || true
i=0
while running verity-ndr-rejected-$$; do
  i=$((i + 1))
  [ $i -lt 30 ] || fail 'registrar kept running after a failed registration'
  sleep 1
done
[ "$(docker inspect -f '{{.State.ExitCode}}' verity-ndr-rejected-$$)" = 1 ] ||
  fail 'registrar did not exit 1 after a failed registration'
docker logs verity-ndr-rejected-$$ 2>&1 | grep -qF 'Registration process failed with error' ||
  fail 'failed registration was not logged'

# Negative: without the kubelet plugin registration directory mounted the
# registrar cannot create its socket and must exit.
status=0
out=$(run_fast verity-ndr-nodir-$$ -v "$csi_volume:/csi" "$image" \
  --csi-address=/csi/csi.sock --kubelet-registration-path="$kubelet_socket") || status=$?
[ "$status" = 1 ] || fail "missing /registration exited $status, want 1"
printf '%s\n' "$out" | grep -qF 'Failed to listen on socket' ||
  fail 'missing /registration error is missing'

printf 'SMOKE PASS version=%s\n' "$expected_version"
