#!/bin/sh
set -eu

# The attacher is started before its CSI socket exists and must keep retrying.
# A pinned upstream CSI hostpath driver with the attach capability then serves
# the socket in a shared volume; the attacher must discover the driver name and
# select the real ControllerPublish handler. The Kubernetes API server is a
# deliberately unreachable kubeconfig endpoint: the attacher must watch
# VolumeAttachment objects through it and keep running, then stop promptly on
# SIGTERM. This exercises the CSI side of the sidecar without a cluster.

image=${1:?usage: test.sh IMAGE}
recipe="$(dirname "$0")/../melange.yaml"
expected_version=$(sed -n 's/^  version: "\([0-9][0-9.]*\)".*$/\1/p' "$recipe")
driver_index='registry.k8s.io/sig-storage/hostpathplugin:v1.17.0@sha256:e20e2681349cb892bc88d8ab23c6785949bdb7e9b518bf3a261b5f13034f8b3b'
label="verity-test=csi-attacher-$$"
volume=verity-csi-attacher-$$
driver=verity-csi-attacher-driver-$$
attacher=verity-csi-attacher-$$

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ -n "$expected_version" ] || fail 'csi-attacher package version not found'

inspect() {
  docker image inspect --format "$1" "$image"
}

[ "$(inspect '{{.Config.User}}')" = 65532 ] || fail 'unexpected OCI user'
[ "$(inspect '{{json .Config.Entrypoint}}')" = '["/usr/bin/csi-attacher"]' ] ||
  fail "unexpected entrypoint: $(inspect '{{json .Config.Entrypoint}}')"

version_out=$(docker run --rm --network none "$image" --version 2>&1) ||
  fail "--version failed: $version_out"
[ "$version_out" = "/usr/bin/csi-attacher v$expected_version" ] ||
  fail "unexpected --version output: $version_out"

usage=$(docker run --rm --network none "$image" -h 2>&1 || true)
printf '%s\n' "$usage" | grep -q -- '-csi-address' || fail 'usage is missing -csi-address'
printf '%s\n' "$usage" | grep -q -- '-leader-election' || fail 'usage is missing -leader-election'

# run_expect_fail NEEDLE ARGS...: the attacher must exit non-zero with NEEDLE in its log.
run_expect_fail() {
  needle=$1
  shift
  if out=$(docker run --rm --network none "$@" 2>&1); then
    fail "expected failure but csi-attacher exited 0 for: $*"
  fi
  printf '%s\n' "$out" | grep -qF -- "$needle" || {
    printf '%s\n' "$out" >&2
    fail "missing '$needle' for: $*"
  }
}

# Outside a cluster and without --kubeconfig there is no API server config.
run_expect_fail 'Failed to build a Kubernetes config' "$image" --csi-address=/csi/csi.sock

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
[ -n "$driver_image" ] || fail 'cannot resolve the CSI driver image'

# The hostpath image has a shell; use it to prepare the shared volume and an
# unreachable kubeconfig readable by the nonroot attacher.
docker volume create --label "$label" "$volume" >/dev/null
docker run --rm --label "$label" -u 0 --network none -v "$volume:/csi" --entrypoint sh "$driver_image" -c '
  set -e
  chmod 0777 /csi
  cat > /csi/kubeconfig <<EOF
apiVersion: v1
kind: Config
clusters:
- name: none
  cluster:
    server: https://127.0.0.1:1
    insecure-skip-tls-verify: true
contexts:
- name: none
  context:
    cluster: none
    user: none
current-context: none
users:
- name: none
  user:
    token: verity-smoke
EOF
  chmod 0644 /csi/kubeconfig
' || fail 'could not prepare the shared volume'

# A non-unix CSI address cannot carry the connection-loss callback.
run_expect_fail 'Failed to connect to the CSI driver' -v "$volume:/csi" "$image" \
  --kubeconfig=/csi/kubeconfig --csi-address=127.0.0.1:10000

# A zero worker count is rejected before any connection attempt.
run_expect_fail 'Option -worker-threads must be greater than zero' -v "$volume:/csi" "$image" \
  --kubeconfig=/csi/kubeconfig --csi-address=/csi/csi.sock --worker-threads=0

# wait_log CONTAINER NEEDLE SECONDS
wait_log() {
  i=0
  while [ "$i" -lt "$3" ]; do
    docker logs "$1" 2>&1 | grep -qF -- "$2" && return 0
    i=$((i + 1))
    sleep 1
  done
  docker logs "$1" >&2 || true
  fail "$1 did not log '$2' within $3s"
}

docker run -d --label "$label" --name "$attacher" --network none -v "$volume:/csi" "$image" \
  --kubeconfig=/csi/kubeconfig --csi-address=/csi/csi.sock --v=2 >/dev/null ||
  fail 'csi-attacher did not start'

# The socket does not exist yet: the attacher must keep waiting, not exit.
wait_log "$attacher" '"Still connecting" address="unix:///csi/csi.sock"' 30
[ "$(docker inspect -f '{{.State.Running}}' "$attacher")" = true ] ||
  fail 'csi-attacher exited while the CSI socket was missing'

docker run -d --label "$label" --name "$driver" --network none --user 65532 \
  -v "$volume:/csi" "$driver_image" \
  --endpoint=unix:///csi/csi.sock --nodeid=verity --drivername=hostpath.csi.k8s.io \
  --statedir=/csi/state --enable-attach=true >/dev/null || fail 'CSI driver did not start'

wait_log "$attacher" 'driver="hostpath.csi.k8s.io"' 60
wait_log "$attacher" 'CSI driver supports ControllerPublishUnpublish, using real CSI handler' 30
[ "$(docker inspect -f '{{.State.Running}}' "$attacher")" = true ] ||
  fail 'csi-attacher exited with a live CSI driver'

# With the CSI side ready the attacher must start its informers against the
# kubeconfig server, and keep running while that server is unreachable.
wait_log "$attacher" 'type="*v1.VolumeAttachment"' 60
docker logs "$attacher" 2>&1 | grep -F 'type="*v1.VolumeAttachment"' |
  grep -qF 'https://127.0.0.1:1/' || fail 'VolumeAttachment watch did not use the kubeconfig server'
[ "$(docker inspect -f '{{.State.Running}}' "$attacher")" = true ] ||
  fail 'csi-attacher exited while the API server was unreachable'

# SIGTERM must stop PID 1 well inside the grace period instead of waiting for
# SIGKILL (137). The Go runtime exits 143, or 2 when the kernel ignores the
# re-raised signal for a namespace init; which one depends on the host.
docker stop -t 30 "$attacher" >/dev/null || fail 'docker stop failed'
code=$(docker inspect -f '{{.State.ExitCode}}' "$attacher")
case "$code" in
  2 | 143) ;;
  *) fail "unexpected csi-attacher exit code after SIGTERM: $code" ;;
esac
# Exit 2 is also the Go runtime's status for a panic or fatal error, so only
# accept it when the log shows no crash.
if docker logs "$attacher" 2>&1 | grep -Eq '^(panic: |fatal error: |goroutine [0-9]+ \[)'; then
  docker logs "$attacher" 2>&1 | tail -n 40 >&2
  fail 'csi-attacher crashed (Go panic or fatal error) instead of stopping on SIGTERM'
fi

printf 'SMOKE PASS version=%s\n' "$expected_version"
