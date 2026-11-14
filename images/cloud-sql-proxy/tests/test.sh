#!/bin/sh
set -eu

# Every container in this test runs with --network none, or joins the network
# namespace of one that does, and uses a fake OAuth2 token with --lazy-refresh,
# so the proxy never reaches a Google API. Listeners are configured so that no
# engine-version lookup is needed at startup: TCP with an explicit --port, and
# the Unix socket with --sql-data (which fixes the engine to Postgres).

image=${1:?usage: test.sh IMAGE}
recipe="$(dirname "$0")/../melange.yaml"
version=$(sed -n 's/^  version: "\([0-9.]*\)".*$/\1/p' "$recipe")
probe_index='docker.io/curlimages/curl:8.14.1@sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b'
label="verity-test=cloud-sql-proxy-$$"
tcp=verity-cloud-sql-proxy-tcp-$$
unix=verity-cloud-sql-proxy-unix-$$
volume=verity-cloud-sql-proxy-sockets-$$
instance='verity-project:us-central1:verity-instance'
work=$(mktemp -d)

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

run() {
  docker run --rm --label "$label" --network none "$image" "$@"
}

[ -n "$version" ] || fail 'could not read the recipe version'

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] ||
  fail 'unexpected OCI user'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/cloud-sql-proxy"]' ] || fail 'unexpected entrypoint'
[ "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ] ||
  fail 'unexpected image command'
[ "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ] ||
  fail 'unexpected working directory'

# The upstream container ldflag stamps +container onto the embedded version.txt.
# stdout only: docker prints a platform mismatch warning on stderr for emulated arm64 runs.
out=$(run --version) || fail 'version failed'
[ "$out" = "cloud-sql-proxy version $version+container" ] ||
  fail "version does not report $version+container: $out"

# reject NAME EXPECTED ARGS...: the proxy exits 1 and stderr carries EXPECTED.
reject() {
  name=$1
  expected=$2
  shift 2
  status=0
  run "$@" >"$work/$name.log" 2>&1 || status=$?
  [ "$status" -eq 1 ] || fail "$name: expected exit 1, got $status: $(cat "$work/$name.log")"
  grep -F -- "$expected" "$work/$name.log" >/dev/null ||
    fail "$name: missing diagnostic '$expected': $(cat "$work/$name.log")"
}

reject missing-instance \
  'Error: missing instance_connection_name (e.g., project:region:instance)' \
  --token fake
reject unknown-flag 'Error: unknown flag: --definitely-not-a-flag' \
  "$instance" --definitely-not-a-flag
reject token-credentials-file \
  'Error: cannot specify --token and --credentials-file flags at the same time' \
  "$instance" --token fake --credentials-file /nonexistent.json
reject token-gcloud-auth \
  'Error: cannot specify --token and --gcloud-auth flags at the same time' \
  "$instance" --token fake --gcloud-auth
reject json-credentials-token \
  'Error: cannot specify --json-credentials and --token flags at the same time' \
  "$instance" --token fake --json-credentials '{}'
reject auto-iam-gcloud-auth \
  'Error: cannot use --auto-iam-authn with --gcloud-auth.' \
  "$instance" --auto-iam-authn --gcloud-auth
reject auto-iam-token \
  'Error: cannot specify --auto-iam-authn and --token without --login-token' \
  "$instance" --auto-iam-authn --token fake
reject unix-socket-port 'Error: cannot specify --unix-socket and --port together' \
  "$instance" --token fake --unix-socket /tmp --port 5432
# The connector parses the name locally before any API request.
reject invalid-instance \
  'Error starting proxy: [not-an-instance] Unable to mount socket: config error: invalid connection name, expected PROJECT:REGION:INSTANCE format or valid DNS domain name (connection name = "not-an-instance")' \
  not-an-instance --token fake --lazy-refresh
grep -F 'The proxy has encountered a terminal error: unable to start:' \
  "$work/invalid-instance.log" >/dev/null ||
  fail "invalid-instance: no terminal error: $(cat "$work/invalid-instance.log")"

# A classic Docker image store cannot bind the index digest to a second
# platform's image, so pull the probe by its own per-platform child digest.
# The index bytes are verified against the pinned digest before a child is
# chosen, which keeps the pin authoritative.
image_arch=$(docker image inspect --format '{{.Architecture}}' "$image")
probe_raw=$(docker buildx imagetools inspect --raw "$probe_index") ||
  fail 'cannot inspect probe image index'
[ "sha256:$(printf '%s' "$probe_raw" | sha256sum | cut -d' ' -f1)" = "${probe_index#*@}" ] ||
  fail 'probe image index digest mismatch'
probe_digest=$(printf '%s' "$probe_raw" |
  jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') ||
  fail 'cannot resolve probe image digest'
case $probe_digest in
  sha256:*) ;;
  *) fail "no unique linux/$image_arch probe image in $probe_index" ;;
esac
probe=docker.io/curlimages/curl@$probe_digest
docker pull --quiet --platform "linux/$image_arch" "$probe" >/dev/null ||
  fail 'cannot pull probe image'

# sidecar CONTAINER ARGS...: run a shell command in CONTAINER's network namespace.
sidecar() {
  target=$1
  shift
  docker run --rm --label "$label" --network "container:$target" --entrypoint sh "$probe" -c "$@"
}

running() {
  [ "$(docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null)" = true ]
}

# wait_log CONTAINER TEXT: wait until the container log contains TEXT.
wait_log() {
  i=0
  until docker logs "$1" 2>&1 | grep -F -- "$2" >/dev/null; do
    running "$1" || { docker logs "$1" >&2; fail "$1 exited while waiting for: $2"; }
    i=$((i + 1))
    [ "$i" -lt 60 ] || { docker logs "$1" >&2; fail "$1 never logged: $2"; }
    sleep 1
  done
}

docker run -d --name "$tcp" --label "$label" --network none "$image" \
  "$instance" --token fake --lazy-refresh --address 127.0.0.1 --port 15432 \
  --health-check --http-address 0.0.0.0 --http-port 9090 >/dev/null ||
  fail 'cannot start TCP proxy'
wait_log "$tcp" 'Starting health check server at 0.0.0.0:9090'
docker logs "$tcp" 2>&1 | grep -F "[$instance] Listening on 127.0.0.1:15432" >/dev/null ||
  fail "TCP listener was not reported: $(docker logs "$tcp" 2>&1)"
docker logs "$tcp" 2>&1 | grep -F 'Authorizing with OAuth2 token' >/dev/null ||
  fail 'the fake token was not used for authorization'

for endpoint in startup liveness readiness; do
  body=$(sidecar "$tcp" "curl -fsS -m 5 http://127.0.0.1:9090/$endpoint") ||
    fail "/$endpoint did not answer 200"
  [ "$body" = ok ] || fail "/$endpoint returned unexpected body: $body"
done
status=$(sidecar "$tcp" "curl -sS -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:9090/nope") ||
  fail 'health server did not answer an unknown path'
[ "$status" = 404 ] || fail "unknown health path returned $status"

# The image's own wait subcommand polls /startup on the same server.
docker exec "$tcp" /usr/bin/cloud-sql-proxy wait --http-port 9090 --max 10s ||
  fail 'cloud-sql-proxy wait did not observe startup'

sidecar "$tcp" 'nc -z -w 5 127.0.0.1 15432' || fail 'configured port 15432 is not listening'
if sidecar "$tcp" 'nc -z -w 2 127.0.0.1 5432'; then
  fail 'unconfigured default port 5432 is listening'
fi

# A client connection offline is accepted, then fails cleanly on the instance
# lookup; the proxy keeps running and stays live.
sidecar "$tcp" 'nc -w 10 127.0.0.1 15432 </dev/null' >/dev/null 2>&1 || true
wait_log "$tcp" "[$instance] failed to connect to instance"
docker logs "$tcp" 2>&1 | grep -F "[$instance] Accepted connection from 127.0.0.1:" >/dev/null ||
  fail 'client connection was not accepted'
running "$tcp" || fail 'proxy exited after a failed client connection'
body=$(sidecar "$tcp" 'curl -fsS -m 5 http://127.0.0.1:9090/liveness') ||
  fail '/liveness failed after a failed client connection'
[ "$body" = ok ] || fail "/liveness after client attempt returned: $body"

# SIGTERM ends the proxy with the upstream exit code 143.
docker stop --time 30 "$tcp" >/dev/null || fail 'cannot stop TCP proxy'
[ "$(docker inspect --format '{{.State.ExitCode}}' "$tcp")" = 143 ] ||
  fail "unexpected SIGTERM exit code: $(docker inspect --format '{{.State.ExitCode}}' "$tcp")"
docker logs "$tcp" 2>&1 | grep -F 'SIGTERM signal received' >/dev/null ||
  fail 'SIGTERM was not reported'
if docker logs "$tcp" 2>&1 | grep -E '^panic:|goroutine [0-9]+ \[' >/dev/null; then
  fail 'proxy panicked'
fi

# Unix socket: the image user creates the Postgres socket in a shared volume.
docker volume create --label "$label" "$volume" >/dev/null
docker run --rm --label "$label" --network none -u 0 -v "$volume:/sockets" \
  --entrypoint chown "$probe" 65532:65532 /sockets || fail 'cannot prepare socket volume'
docker run -d --name "$unix" --label "$label" --network none -v "$volume:/sockets" "$image" \
  "$instance" --token fake --lazy-refresh --sql-data --unix-socket /sockets >/dev/null ||
  fail 'cannot start Unix socket proxy'
socket="/sockets/$instance/.s.PGSQL.5432"
wait_log "$unix" "[$instance] Listening on $socket"
docker run --rm --label "$label" --network none -v "$volume:/sockets" --entrypoint sh "$probe" \
  -c "test -S '$socket' && [ \"\$(stat -c %u '$socket')\" = 65532 ]" ||
  fail "Unix socket $socket is missing or not owned by 65532"
docker run --rm --label "$label" --network none -v "$volume:/sockets" --entrypoint sh "$probe" \
  -c "curl -sS -m 10 --unix-socket '$socket' http://localhost/" >/dev/null 2>&1 || true
wait_log "$unix" "[$instance] Accepted connection from"
running "$unix" || fail 'Unix socket proxy exited after a client connection'

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$version"
