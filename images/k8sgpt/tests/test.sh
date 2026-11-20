#!/bin/sh
set -eu

# Behavior that needs neither a cluster nor a reachable AI backend. Every
# container runs with a read-only root filesystem and no capabilities. The
# image must:
#   - report the recipe version and source commit;
#   - list the built-in analyzers and document the analyze flags;
#   - fail clearly on an unknown command, on analyze without a kubeconfig, and
#     on serve without a configured AI provider;
#   - start serve with the offline noopai backend on an internal network,
#     persist that provider under XDG_CONFIG_HOME (the k8sgpt-operator
#     contract), answer gRPC through the REST gateway on 8080, serve /healthz
#     and /metrics on 8081, and reach the analyzer, which must report the
#     missing kubeconfig instead of crashing;
#   - stop on SIGTERM without a Go crash.

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

curl_index='docker.io/curlimages/curl:8.14.1@sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b'

id=$$
label="verity-test=k8sgpt-$id"
network="verity-k8sgpt-cli-$id"
srv="verity-k8sgpt-serve-$id"
data="verity-k8sgpt-data-$id"
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  docker logs "$srv" 2>&1 | tail -n 30 >&2 || true
  exit 1
}

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  docker volume rm "$data" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

recipe="$here/../melange.yaml"
expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' "$recipe")
expected_commit=$(awk '$1 == "source-commit:" { print $2; exit }' "$recipe")
[ -n "$expected_version" ] || fail 'could not read the recipe version'
[ -n "$expected_commit" ] || fail 'could not read the recipe source commit'

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] ||
  fail 'unexpected OCI user'
# The upstream image and the k8sgpt-operator Deployment pass only arguments.
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/k8sgpt"]' ] ||
  fail 'unexpected entrypoint'

# out NAME ARGS...: run the image under a 60s bound with a writable tmpfs HOME;
# record status and output. A timeout is a failure: every case must exit.
out() {
  name=$1
  shift
  status=0
  timeout 60 docker run --rm --label "$label" --read-only --cap-drop=ALL \
    --tmpfs /home/nonroot:uid=65532,gid=65532 "$@" >"$work/$name.out" 2>&1 || status=$?
  [ "$status" != 124 ] || fail "$name: timed out"
}

expect_ok() {
  name=$1
  shift
  out "$name" "$@"
  [ "$status" = 0 ] || fail "$name exited $status: $(head -n 8 "$work/$name.out")"
}

expect_fail() {
  name=$1
  message=$2
  shift 2
  out "$name" "$@"
  [ "$status" != 0 ] || fail "$name: unexpectedly succeeded"
  grep -qF -- "$message" "$work/$name.out" ||
    fail "$name: missing '$message': $(head -n 8 "$work/$name.out")"
}

expect_ok version --network none "$image" version
version_line=$(head -n 1 "$work/version.out")
case $version_line in
  "k8sgpt: $expected_version ($expected_commit), built at: "[0-9][0-9][0-9][0-9]-*) ;;
  *) fail "unexpected version output: $version_line" ;;
esac

expect_ok filters --network none "$image" filters list
grep -qx 'Active: ' "$work/filters.out" || fail 'filters list has no Active section'
grep -qx 'Unused: ' "$work/filters.out" || fail 'filters list has no Unused section'
for f in Pod Deployment Service Node; do
  grep -qx "> $f" "$work/filters.out" || fail "filters list does not list $f"
done

expect_ok analyze-help --network none "$image" analyze --help
for f in --explain --filter --backend --namespace --output; do
  grep -qF -- "$f" "$work/analyze-help.out" || fail "analyze --help does not list $f"
done

expect_fail unknown-command 'unknown command "no-such-command"' \
  --network none "$image" no-such-command
expect_fail analyze-no-kubeconfig 'no configuration has been provided' \
  --network none "$image" analyze
expect_fail serve-no-provider 'AI provider not specified in configuration' \
  --network none "$image" serve
expect_fail serve-bad-temperature 'temperature ranges from 0 to 1' \
  --network none -e K8SGPT_BACKEND=noopai -e K8SGPT_TEMPERATURE=2 "$image" serve

# image_arch, pull_child: resolve the pinned curl index to the candidate's
# platform child, verifying the index bytes against the pin.
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

# The operator mounts a writable volume at /k8sgpt-data and points the XDG
# directories into it; the root filesystem stays read-only. A named volume
# keeps files owned by the image user off the host.
docker volume create --label "$label" "$data" >/dev/null || fail 'could not create the data volume'
docker run --rm --label "$label" --network none -u 0 -v "$data:/k8sgpt-data" \
  --entrypoint chown "$curl_image" 65532:65532 /k8sgpt-data || fail 'could not prepare the data volume'
docker network create --internal --label "$label" "$network" >/dev/null
docker run -d --label "$label" --name "$srv" --network "$network" --read-only --cap-drop=ALL \
  -v "$data:/k8sgpt-data" -e XDG_CONFIG_HOME=/k8sgpt-data/.config \
  -e XDG_CACHE_HOME=/k8sgpt-data/.cache -e K8SGPT_BACKEND=noopai \
  "$image" serve --http >/dev/null || fail 'serve did not start'

# probe METHOD PORT PATH: body, then the HTTP status on the last line.
probe() {
  docker run --rm --label "$label" --network "$network" "$curl_image" -s --max-time 10 \
    -X "$1" -o /dev/stdout -w '\n%{http_code}' "http://$srv:$2$3" 2>/dev/null || true
}

healthz=
i=0
while [ "$i" -lt 30 ]; do
  [ "$(docker inspect -f '{{.State.Running}}' "$srv" 2>/dev/null)" = true ] ||
    fail "serve exited $(docker inspect -f '{{.State.ExitCode}}' "$srv" 2>/dev/null)"
  healthz=$(probe GET 8081 /healthz)
  [ "$(printf '%s\n' "$healthz" | tail -n 1)" = 200 ] && break
  i=$((i + 1))
  sleep 1
done
[ "$(printf '%s\n' "$healthz" | tail -n 1)" = 200 ] || fail "healthz did not return 200: $healthz"

metrics=$(probe GET 8081 /metrics)
[ "$(printf '%s\n' "$metrics" | tail -n 1)" = 200 ] || fail 'metrics did not return 200'
printf '%s\n' "$metrics" | grep -q '^go_info{version="go' || fail 'metrics are missing go_info'

# The gateway proxies to the gRPC server on the same port, so a JSON reply
# proves both. ListIntegrations needs no cluster.
list=$(probe GET 8080 /v1/list)
[ "$(printf '%s\n' "$list" | tail -n 1)" = 200 ] || fail "GET /v1/list: $list"
printf '%s\n' "$list" | head -n 1 | jq -e 'has("trivy")' >/dev/null ||
  fail "GET /v1/list returned unexpected JSON: $list"
wrong=$(probe POST 8080 /v1/list)
[ "$(printf '%s\n' "$wrong" | tail -n 1)" = 501 ] || fail "POST /v1/list was not rejected: $wrong"

# Analyze reaches the analyzer service, which must fail on the missing cluster
# configuration rather than crash the server.
analyze=$(probe POST 8080 /v1/analyze)
[ "$(printf '%s\n' "$analyze" | tail -n 1)" = 500 ] || fail "POST /v1/analyze: $analyze"
printf '%s\n' "$analyze" | head -n 1 | jq -e '.message | contains("initialising kubernetes client")' \
  >/dev/null || fail "unexpected analyze error: $analyze"
[ "$(docker inspect -f '{{.State.Running}}' "$srv")" = true ] || fail 'serve exited after analyze'

config=$(docker run --rm --label "$label" --network none -u 0 -v "$data:/k8sgpt-data:ro" \
  --entrypoint cat "$curl_image" /k8sgpt-data/.config/k8sgpt/k8sgpt.yaml) ||
  fail 'serve did not write its configuration under XDG_CONFIG_HOME'
printf '%s\n' "$config" | grep -qE '^ +- name: noopai$' ||
  fail "configuration does not record noopai: $config"
printf '%s\n' "$config" | grep -qx "version: $expected_version" ||
  fail 'configuration does not record the version'

docker logs "$srv" >"$work/run.log" 2>&1
grep -qF '"msg":"binding api to 8080"' "$work/run.log" || fail 'serve did not bind the API to 8080'
grep -qF '"msg":"binding metrics to 8081"' "$work/run.log" || fail 'serve did not bind metrics to 8081'
grep -qF '"msg":"enabling rest/http api"' "$work/run.log" || fail 'serve did not enable the REST gateway'

# serve installs no signal handler, so SIGTERM ends it through the Go runtime:
# status 143, or 2 when the kernel ignores the re-raised signal for a PID 1
# process. 137 would mean docker had to SIGKILL it.
docker stop --time 10 "$srv" >/dev/null
code=$(docker inspect --format '{{.State.ExitCode}}' "$srv")
case $code in
  2 | 143) ;;
  *) fail "serve did not stop on SIGTERM: exit $code" ;;
esac
# Exit 2 is also the Go runtime's status for a panic or fatal error, so only
# accept it when the log shows no crash.
docker logs "$srv" >"$work/shutdown.log" 2>&1 || fail 'could not read the serve log after SIGTERM'
if grep -Eq '^(panic: |fatal error: |goroutine [0-9]+ \[)' "$work/shutdown.log"; then
  fail "serve crashed on SIGTERM: $(grep -E '^(panic: |fatal error: )' "$work/shutdown.log" | head -n 1)"
fi

printf 'SMOKE PASS version=%s\n' "$expected_version"
