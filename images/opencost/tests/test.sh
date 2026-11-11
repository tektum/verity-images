#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
label=verity.test=opencost-$$
container="verity-opencost-test-$$"
work=$(mktemp -d)

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -f >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  docker logs "$container" >&2 2>/dev/null || true
  printf '%s\n' "$1" >&2
  exit 1
}

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
expected_commit=$(awk '$1 == "source-commit:" { print substr($2, 1, 7); exit }' \
  "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'
[ -n "$expected_commit" ] || fail 'could not read the recipe source commit'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/opencost"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'CA bundle environment is missing'

docker run --rm --network none --read-only "$image" --help >"$work/help" 2>&1 ||
  fail 'opencost --help failed'
grep -F 'Cost-Model metric exporter and data aggregator.' "$work/help" >/dev/null ||
  fail 'help is missing the cost-model description'
for flag in --port --kubernetes-enabled --cloud-cost-enabled; do
  grep -F -e "$flag" "$work/help" >/dev/null || fail "help is missing $flag"
done

# Upstream main.go calls log.Fatal().Err(err) without sending the event, so flag parse errors
# print the diagnostic and exit 0. Assert the diagnostic and that the process stops instead of serving.
timeout 30 docker run --rm --network none --read-only "$image" --definitely-invalid \
  >"$work/invalid" 2>&1 || fail 'invalid flag run did not stop on its own'
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'invalid flag diagnostic is missing'
if grep -F 'HTTP server starting' "$work/invalid" >/dev/null; then
  fail 'invalid flag still started the server'
fi

timeout 30 docker run --rm --network none --read-only "$image" --port=not-a-port \
  >"$work/badport" 2>&1 || fail 'invalid port run did not stop on its own'
grep -F 'invalid argument "not-a-port" for "--port" flag' "$work/badport" >/dev/null ||
  fail 'invalid port diagnostic is missing'
if grep -F 'HTTP server starting' "$work/badport" >/dev/null; then
  fail 'invalid port still started the server'
fi

# Kubernetes mode without a cluster must stop with a readable error, not hang or crash.
if timeout 60 docker run --rm --network none --read-only "$image" --kubernetes-enabled \
  >"$work/nokube" 2>&1; then
  fail 'kubernetes mode without a cluster unexpectedly succeeded'
fi
grep -F 'Failed to build Kubernetes client' "$work/nokube" >/dev/null ||
  fail 'missing kubernetes configuration diagnostic is missing'

# The default pricing models of the upstream image are shipped.
docker create --label "$label" --name "$container-files" "$image" >/dev/null
docker cp "$container-files:/models/default.json" "$work/default.json" ||
  fail '/models/default.json is missing from the image'
grep -F '"provider"' "$work/default.json" >/dev/null ||
  fail '/models/default.json has no provider key'

docker run -d --label "$label" --name "$container" --read-only \
  -p 127.0.0.1::9003 "$image" >/dev/null
port=$(docker port "$container" 9003/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || fail 'opencost port was not published'
base="http://127.0.0.1:$port"

attempts=0
until curl --silent --fail --max-time 5 --output /dev/null "$base/healthz" 2>/dev/null; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || fail 'opencost /healthz did not become ready'
  [ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ] ||
    fail 'opencost exited before it became healthy'
  sleep 1
done

docker logs "$container" 2>&1 |
  grep -F "Starting cost-model version $expected_version ($expected_commit)" >/dev/null ||
  fail "startup log does not report version $expected_version ($expected_commit)"

curl --silent --fail --max-time 10 "$base/metrics" >"$work/metrics" ||
  fail '/metrics request failed'
grep -E '^go_goroutines [0-9]+' "$work/metrics" >/dev/null ||
  fail '/metrics does not serve process metrics'

docker stop -t 20 "$container" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ] ||
  fail 'opencost did not exit cleanly on SIGTERM'

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$expected_version"
