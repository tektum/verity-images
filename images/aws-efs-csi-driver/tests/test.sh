#!/bin/sh
set -eu

# Offline behavior test for the Amazon EFS CSI driver image. Nothing reaches
# AWS or Kubernetes: every container runs with --network none or joins the
# network namespace of a fake ECS task metadata server that itself has no
# network. The driver resolves its node identity from that server (the
# documented ECS path) and serves CSI on a Unix socket in a shared volume.
#
# 1. OCI contract, --version, usage and flag/option errors.
# 2. Bundled efs-utils: mount.efs, efs-proxy, stunnel(5), mount.nfs4, botocore
#    and the static configs the driver copies at startup.
# 3. Without any metadata source the driver refuses to start.
# 4. With the fake task metadata it starts the efs-utils watchdog, creates the
#    CSI socket, and a pinned upstream livenessprobe completes the CSI Identity
#    handshake (GetPluginInfo + Probe) over that socket.

image=${1:?usage: test.sh IMAGE}
recipe="$(dirname "$0")/../melange.yaml"
expected_version=$(sed -n 's/^  version: "\([0-9][0-9.]*\)".*$/v\1/p' "$recipe")
expected_commit=$(sed -n 's/^  source-commit: \([0-9a-f]\{40\}\)$/\1/p' "$recipe")
probe_index='registry.k8s.io/sig-storage/livenessprobe:v2.20.0@sha256:19f2cf2f40e1987c7943945deca5f65cd4e4bf5cc0657fc78a5df131861578e8'
label="verity-test=aws-efs-csi-driver-$$"
volume=verity-efs-csi-$$
tmds=verity-efs-tmds-$$
driver=verity-efs-driver-$$
probe=verity-efs-probe-$$
socket=/csi/csi.sock
driver_name=efs.csi.aws.com

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
  docker logs "$1" 2>&1 | tail -n 60 >&2 || true
}

[ -n "$expected_version" ] || fail 'driver package version not found'
[ -n "$expected_commit" ] || fail 'driver source commit not found'

inspect() {
  docker image inspect --format "$1" "$image"
}

# Upstream Dockerfile: root, ENTRYPOINT ["/bin/aws-efs-csi-driver"].
[ "$(inspect '{{.Config.User}}')" = 0 ] || fail "unexpected OCI user: $(inspect '{{.Config.User}}')"
[ "$(inspect '{{json .Config.Entrypoint}}')" = '["/bin/aws-efs-csi-driver"]' ] ||
  fail "unexpected entrypoint: $(inspect '{{json .Config.Entrypoint}}')"
[ "$(inspect '{{.Config.WorkingDir}}')" = / ] || fail "unexpected workdir: $(inspect '{{.Config.WorkingDir}}')"

version=$(docker run --rm --network none "$image" --version) || fail '--version failed'
for want in "\"driverVersion\": \"$expected_version\"" "\"gitCommit\": \"$expected_commit\"" \
  '"efsClientSource": "k8s"' '"platform": "linux/'; do
  printf '%s\n' "$version" | grep -qF -- "$want" || {
    printf '%s\n' "$version" >&2
    fail "--version is missing $want"
  }
done

usage=$(docker run --rm --network none "$image" -h 2>&1 || true)
for flag in endpoint efs-utils-config-dir-path efs-utils-static-files-path \
  vol-metrics-opt-in delete-access-point-root-dir; do
  printf '%s\n' "$usage" | grep -q -- "-$flag" || fail "usage is missing -$flag"
done

# expect_exit NAME STATUS PATTERN [docker args --] ARGS...: the run exits STATUS and logs PATTERN.
expect_exit() {
  name=$1 want=$2 pattern=$3
  shift 3
  status=0
  out=$(timeout 120 docker run --rm --network none "$image" "$@" 2>&1) || status=$?
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
expect_exit 'bad bool' 2 'invalid boolean value "maybe" for -vol-metrics-opt-in' --vol-metrics-opt-in=maybe
expect_exit 'invalid options' 1 \
  'maxInflightMountCallsOptIn is true, but maxInflightMountCalls is not set to a positive value' \
  --max-inflight-mount-calls-opt-in
expect_exit 'no metadata source' 255 'could not create MetadataProvider from any source' \
  --endpoint=unix:///tmp/csi.sock

# helper NAME SCRIPT: run a shell script in the image without network.
helper() {
  docker run --rm --network none --entrypoint /bin/sh "$image" -c "$2" 2>&1 ||
    fail "$1 failed"
}

# Bundled efs-utils and mount helpers (upstream installs amazon-efs-utils,
# stunnel with a stunnel5 link, mount.nfs4, mount/umount and botocore).
efs_utils=$(helper 'mount.efs --version' 'mount.efs --version')
printf '%s\n' "$efs_utils" | grep -Eq 'Version: 3\.[0-9]+\.[0-9]+' ||
  fail "unexpected mount.efs --version: $efs_utils"
# shellcheck disable=SC2016
helper 'mount helpers' '
  set -e
  for cmd in mount umount mount.efs mount.s3files mount.nfs4 efs-proxy stunnel stunnel5 \
    amazon-efs-mount-watchdog python3; do
    command -v "$cmd" >/dev/null || { echo "missing $cmd"; exit 1; }
  done
  efs-proxy --help | grep -q "^Usage: efs-proxy"
  stunnel -version 2>&1 | grep -q "^stunnel 5"
  [ "$(readlink -f "$(command -v stunnel5)")" = "$(readlink -f "$(command -v stunnel)")" ]
  mount.nfs4 -V 2>&1 | grep -q nfs-utils
  python3 -c "import botocore, ssl"
  mount --version | grep -q util-linux
  for f in efs-utils.conf s3files-utils.conf efs-utils.crt; do
    test -s "/etc/amazon/efs-static-files/$f" || { echo "missing static $f"; exit 1; }
  done
  ! test -e /etc/amazon/efs
'

image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
# pull_child INDEX: pull the pinned index by its per-platform child digest.
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
probe_image=$(pull_child "$probe_index") || exit 1
[ -n "$probe_image" ] || fail 'cannot resolve the livenessprobe image'

# wait_log NAME PATTERN SECONDS
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

docker volume create --label "$label" "$volume" >/dev/null

# Fake ECS task metadata v4 endpoint, served by the image's own python3.
docker run -d --label "$label" --name "$tmds" --network none --entrypoint python3 "$image" -c '
import http.server, json
body = json.dumps({"Cluster": "verity", "TaskARN": "arn:aws:ecs:us-west-2:000000000000:task/verity/0123456789abcdef",
                   "AvailabilityZone": "us-west-2a"}).encode()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        code = 200 if self.path == "/v4/task" else 404
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        if code == 200:
            self.wfile.write(body)
http.server.HTTPServer(("127.0.0.1", 51679), H).serve_forever()
' >/dev/null || fail 'fake task metadata server did not start'
i=0
until docker exec "$tmds" python3 -c '
import urllib.request
urllib.request.urlopen("http://127.0.0.1:51679/v4/task", timeout=2)
' >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || { show_logs "$tmds"; fail 'fake task metadata server not ready after 30s'; }
  sleep 1
done

# /var/amazon/efs stands in for the chart's efs-utils-config hostPath mount.
docker run -d --label "$label" --name "$driver" --network "container:$tmds" \
  -e ECS_CONTAINER_METADATA_URI_V4=http://127.0.0.1:51679/v4 -e AWS_REGION=us-west-2 \
  -v "$volume:/csi" --tmpfs /var/amazon/efs "$image" --endpoint="unix://$socket" --v=4 >/dev/null ||
  fail 'driver did not start'

wait_log "$driver" 'detected driver is running in ECS' 60
wait_log "$driver" 'Starting efs-utils watchdog' 60
wait_log "$driver" 'Starting reaper' 30
i=0
until docker exec "$driver" test -S "$socket"; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || { show_logs "$driver"; fail "driver did not create $socket"; }
  sleep 1
done
sleep 2
running "$driver" || { show_logs "$driver"; fail 'driver exited after startup'; }

# The driver linked /etc/amazon/efs to its config dir, copied the efs-utils
# static files there and runs amazon-efs-mount-watchdog from efs-utils.
# shellcheck disable=SC2016
docker exec "$driver" sh -c '
  set -e
  [ "$(readlink /etc/amazon/efs)" = /var/amazon/efs ]
  for f in efs-utils.conf s3files-utils.conf efs-utils.crt; do test -s "/etc/amazon/efs/$f"; done
  ps -o args | grep -v grep | grep -q amazon-efs-mount-watchdog
' || { show_logs "$driver"; fail 'efs-utils config or watchdog not set up by the driver'; }

# With the driver-managed config in place, mount.efs parses its config and
# rejects bad invocations instead of crashing.
out=$(docker exec "$driver" mount.efs 2>&1 || true)
printf '%s\n' "$out" | grep -qF 'Usage: mount.efs' || { printf '%s\n' "$out" >&2; fail 'mount.efs did not print usage'; }
status=0
out=$(timeout 120 docker exec "$driver" mount.efs fs-12345678 /tmp 2>&1) || status=$?
[ "$status" != 0 ] || fail 'offline mount.efs unexpectedly succeeded'
[ "$status" != 124 ] || fail 'offline mount.efs timed out'
if printf '%s\n' "$out" | grep -q Traceback; then
  printf '%s\n' "$out" >&2
  fail 'mount.efs crashed'
fi

# CSI Identity handshake through a pinned upstream livenessprobe.
docker run -d --label "$label" --name "$probe" --network "container:$tmds" \
  -v "$volume:/csi" "$probe_image" --csi-address="$socket" --health-port=9808 >/dev/null ||
  fail 'livenessprobe did not start'
healthz() {
  docker exec "$tmds" python3 -c '
import urllib.request, urllib.error
try:
    print(urllib.request.urlopen("http://127.0.0.1:9808/healthz", timeout=10).status)
except urllib.error.HTTPError as e:
    print(e.code)
except Exception:
    print("down")
' 2>/dev/null || true
}
i=0
status=
while [ "$i" -lt 30 ]; do
  status=$(healthz)
  [ "$status" = 200 ] && break
  i=$((i + 1))
  sleep 1
done
[ "$status" = 200 ] || { show_logs "$probe"; show_logs "$driver"; fail "healthz did not report 200: $status"; }
docker logs "$probe" 2>&1 | grep -qF "$driver_name" ||
  { show_logs "$probe"; fail "livenessprobe did not report driver $driver_name"; }

# Negative: once the driver is gone the Probe handshake fails.
docker rm -f "$driver" >/dev/null
sleep 2
status=$(healthz)
case "$status" in
  200) fail 'healthz still reported 200 after the driver stopped' ;;
  5??) ;;
  *) fail "unexpected healthz status after the driver stopped: $status" ;;
esac

printf 'SMOKE PASS version=%s\n' "$expected_version"
