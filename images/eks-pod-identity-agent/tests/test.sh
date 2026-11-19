#!/bin/sh
# Smoke test for the EKS Pod Identity Agent image. Every agent container runs
# with --network none and AWS_EC2_METADATA_DISABLED=true, so no case can reach
# AWS, EC2 instance metadata or a Kubernetes API server. HTTP requests come
# from a pinned curl container in the agent's network namespace, so nothing is
# published on the host.
set -eu

image=${1:?usage: test.sh IMAGE}
recipe="$(dirname "$0")/../melange.yaml"
expected_version=$(sed -n 's/^  version: "\([0-9][0-9.]*\)".*$/\1/p' "$recipe")
curl_index='docker.io/curlimages/curl:8.14.1@sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b'
label="verity-test=eks-pod-identity-agent-$$"
name="verity-eks-pod-identity-agent-$$"
agent="verity-eks-pod-identity-agent-server-$$"
csi="verity-eks-pod-identity-agent-csi-$$"
# Startup failures without the node link or a cluster must be fast.
max_seconds=20

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -f >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

[ -n "$expected_version" ] || fail 'package version not found'

inspect() {
  docker image inspect --format "$1" "$image"
}

# OCI contract: upstream runs as root with the binaries at / and no
# entrypoint; this image adds the agent as entrypoint and keeps both paths.
[ "$(inspect '{{.Config.User}}')" = 0 ] || fail "unexpected OCI user: $(inspect '{{.Config.User}}')"
[ "$(inspect '{{json .Config.Entrypoint}}')" = '["/usr/bin/eks-pod-identity-agent"]' ] ||
  fail "unexpected entrypoint: $(inspect '{{json .Config.Entrypoint}}')"
[ "$(inspect '{{json .Config.Cmd}}')" = null ] || fail 'unexpected default command'
[ "$(inspect '{{.Config.WorkingDir}}')" = / ] || fail 'unexpected working directory'

# run ARGS...: run the image offline; sets $output, $status and $elapsed.
run() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  started=$(date +%s)
  status=0
  output=$(timeout 120 docker run --name "$name" --label "$label" --network none \
    -e AWS_EC2_METADATA_DISABLED=true "$@" 2>&1) || status=$?
  elapsed=$(($(date +%s) - started))
  docker rm -f "$name" >/dev/null 2>&1 || true
}

contains() {
  case $1 in
    *"$2"*) return 0 ;;
  esac
  return 1
}

# expect_failure DESCRIPTION CODE TEXT ARGS...: the run exits with CODE within
# $max_seconds and its output contains TEXT.
expect_failure() {
  description=$1 code=$2 text=$3
  shift 3
  run "$@"
  if [ "$status" -ne "$code" ]; then
    printf '%s\n' "$output" >&2
    fail "$description: exit status $status, expected $code"
  fi
  if [ "$elapsed" -gt "$max_seconds" ]; then
    printf '%s\n' "$output" >&2
    fail "$description: took ${elapsed}s, expected at most ${max_seconds}s"
  fi
  contains "$output" "$text" || {
    printf '%s\n' "$output" >&2
    fail "$description: missing '$text'"
  }
}

# The CLI lists the subcommands the Helm chart runs.
run "$image" --help
[ "$status" -eq 0 ] || fail "--help exited $status"
for command in initialize server version; do
  contains "$output" "  $command " || fail "--help does not list $command"
done

# The version comes from the pinned release, through both the entrypoint and
# the upstream /eks-pod-identity-agent path the chart's commands use.
run "$image" version
[ "$status" -eq 0 ] || fail "version exited $status"
printf '%s\n' "$output" | grep -Fqx "EKS Pod Identity Agent version $expected_version" ||
  fail "unexpected version output: $output"
run --entrypoint /eks-pod-identity-agent "$image" version
[ "$status" -eq 0 ] || fail "/eks-pod-identity-agent version exited $status"
printf '%s\n' "$output" | grep -Fqx "EKS Pod Identity Agent version $expected_version" ||
  fail "unexpected /eks-pod-identity-agent version output: $output"

# server --help lists the flags the chart passes.
run "$image" server --help
[ "$status" -eq 0 ] || fail "server --help exited $status"
for flag in --port --cluster-name --probe-port --metrics-port --bind-hosts \
  --enable-workload-identity --rotate-credentials; do
  contains "$output" "$flag" || fail "server --help does not list $flag"
done

expect_failure 'unknown flag' 1 'unknown flag: --no-such-flag' "$image" --no-such-flag

# initialize creates the pod-id-link0 interface; without NET_ADMIN (the chart
# runs it privileged) it must fail at once instead of half-configuring.
expect_failure 'initialize without NET_ADMIN' 1 \
  'Unable to initalize agent: unable to create interface pod-id-link0: operation not permitted' \
  --cap-drop ALL "$image" initialize

# Without the link-local addresses that initialize creates, the server must
# exit instead of serving on some other address.
expect_failure 'server without pod-id-link0' 1 'Unable to start server' \
  "$image" server --cluster-name verity-smoke

# pull_child INDEX: pull the pinned index by its per-platform child digest,
# verifying the index bytes against the pin first. A classic Docker image store
# cannot bind an index digest to a second platform.
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
curl_image=$(pull_child "$curl_index") || exit 1
[ -n "$curl_image" ] || fail 'cannot resolve the curl image'

# A running server on loopback: the agent starts without a cluster (token
# validation is skipped with a logged reason), serves its probes and metrics,
# and refuses credential requests that do not arrive on the agent addresses.
docker run -d --name "$agent" --label "$label" --network none \
  -e AWS_EC2_METADATA_DISABLED=true -e AWS_REGION=us-west-2 \
  --cap-drop ALL --cap-add NET_BIND_SERVICE \
  "$image" server --cluster-name verity-smoke --bind-hosts 127.0.0.1 --port 80 \
  --probe-port 2703 --metrics-address 127.0.0.1 --metrics-port 2705 >/dev/null ||
  fail 'agent server did not start'

curl_in() {
  docker run --rm --label "$label" --network "container:$agent" "$curl_image" \
    -s --max-time 10 "$@" 2>/dev/null || true
}

status=
i=0
while [ "$i" -lt 30 ]; do
  status=$(curl_in -o /dev/null -w '%{http_code}' http://127.0.0.1:2703/healthz)
  [ "$status" = 200 ] && break
  i=$((i + 1))
  sleep 1
done
if [ "$status" != 200 ]; then
  docker logs "$agent" >&2 2>&1 || true
  fail "/healthz returned '$status'"
fi
[ "$(curl_in -o /dev/null -w '%{http_code}' http://127.0.0.1:2703/readyz)" = 200 ] ||
  fail '/readyz is not 200'

response=$(curl_in -H 'Authorization: verity-smoke' http://127.0.0.1:80/v1/credentials)
contains "$response" 'Access Denied. Called agent through invalid address' || {
  docker logs "$agent" >&2 2>&1 || true
  fail "credential request was not denied: $response"
}
code=$(curl_in -o /dev/null -w '%{http_code}' -H 'Authorization: verity-smoke' \
  http://127.0.0.1:80/v1/credentials)
[ "$code" = 403 ] || fail "credential request status: $code"

metrics=$(curl_in http://127.0.0.1:2705/metrics)
contains "$metrics" 'pod_identity_http_response{code="403"} 2' || {
  printf '%s\n' "$metrics" >&2
  fail 'metrics do not count the denied request'
}

docker inspect -f '{{.State.Running}}' "$agent" | grep -qx true || fail 'agent exited'
logs=$(docker logs "$agent" 2>&1)
contains "$logs" 'failed to build in-cluster config' ||
  { printf '%s\n' "$logs" >&2; fail 'missing in-cluster config diagnostic'; }
contains "$logs" "Pod Identity Agent version $expected_version" ||
  { printf '%s\n' "$logs" >&2; fail 'server log does not report the version'; }

# The CSI node plugin waits for the agent's workload identity socket before it
# registers, through the upstream /eks-pod-identity-csi-driver path.
docker run -d --name "$csi" --label "$label" --network none --cap-drop ALL \
  --entrypoint /eks-pod-identity-csi-driver "$image" -v info >/dev/null ||
  fail 'CSI driver did not start'
i=0
logs=
while [ "$i" -lt 20 ]; do
  logs=$(docker logs "$csi" 2>&1)
  contains "$logs" 'Waiting for the agent to serve' && break
  i=$((i + 1))
  sleep 1
done
contains "$logs" 'Waiting for the agent to serve /var/run/secrets/pods.eks.amazonaws.com/workloadidentity/agent.sock' ||
  { printf '%s\n' "$logs" >&2; fail 'CSI driver does not wait for the agent socket'; }
contains "$logs" "Pod Identity Agent CSI driver version $expected_version" ||
  { printf '%s\n' "$logs" >&2; fail 'CSI driver log does not report the version'; }
docker inspect -f '{{.State.Running}}' "$csi" | grep -qx true || fail 'CSI driver exited'

printf 'SMOKE PASS image=%s\n' "$image"
