#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE [FLAVOR]}
flavor=${2:-plain}
expected_version=$(sed -n 's/^  version: "\([^"]*\)".*$/\1/p' "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image")
container=verity-nifi-registry-$$
invalid_container=$container-invalid
home=/opt/nifi-registry/nifi-registry-current
work=$(mktemp -d)

cleanup() {
  docker rm -f "$container" "$invalid_container" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

case $flavor in plain) ;; *) fail "unsupported flavor $flavor" ;; esac

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 1000 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = \
  '["/opt/nifi-registry/scripts/start.sh"]' ] || fail 'unexpected entrypoint'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = "$home" ] ||
  fail 'unexpected working directory'
docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -qx "NIFI_REGISTRY_HOME=$home" || fail 'NIFI_REGISTRY_HOME is not set'
[ "$(docker run --rm --platform "$platform" --entrypoint id "$image" -u)" = 1000 ] ||
  fail 'runtime user is not 1000'
docker run --rm --platform "$platform" --entrypoint java "$image" -version 2>&1 |
  grep -q 'version "21\.' || fail 'Java 21 runtime is missing'
docker run --rm --platform "$platform" --entrypoint readlink "$image" \
  "/opt/nifi-registry/nifi-registry-$expected_version" | grep -qx nifi-registry-current ||
  fail 'versioned home symlink is missing'
for dir in conf database extension_bundles flow_storage logs run work; do
  docker run --rm --platform "$platform" --entrypoint test "$image" -w "$home/$dir" ||
    fail "$home/$dir is not writable by the runtime user"
done

wait_ready() {
  i=0
  until curl -fsS --max-time 3 "http://127.0.0.1:$port/nifi-registry-api/about" \
    >"$work/about.json" 2>/dev/null; do
    [ "$(docker inspect -f '{{.State.Running}}' "$container")" = true ] || {
      docker logs "$container" >&2
      fail 'nifi-registry exited before becoming ready'
    }
    i=$((i + 1))
    [ "$i" -lt 180 ] || {
      docker logs "$container" >&2
      fail 'nifi-registry did not become ready'
    }
    sleep 1
  done
}

docker run -d --platform "$platform" --name "$container" -p 127.0.0.1::18080 "$image" >/dev/null
port=$(docker port "$container" 18080/tcp | awk -F: 'NR == 1 { print $NF }')
[ -n "$port" ] || fail 'HTTP port 18080 is not published'
wait_ready
grep -q "\"registryAboutVersion\":\"$expected_version\"" "$work/about.json" ||
  { cat "$work/about.json" >&2; fail "about does not report version $expected_version"; }

curl -fsS "http://127.0.0.1:$port/nifi-registry-api/access" | grep -q '"anonymous":true' ||
  fail 'unsecured access does not report the anonymous identity'
curl -fsS "http://127.0.0.1:$port/nifi-registry/" | grep -qi '<html' ||
  fail 'web UI is not served'

bucket=$(curl -fsS -X POST -H 'Content-Type: application/json' \
  -d '{"name":"verity-smoke","description":"smoke test"}' \
  "http://127.0.0.1:$port/nifi-registry-api/buckets" |
  sed -n 's/.*"identifier":"\([0-9a-f-]*\)".*/\1/p')
[ -n "$bucket" ] || fail 'bucket creation returned no identifier'

# Negative: a bucket without a name is rejected by the API.
status=$(curl -sS -o "$work/bad-bucket.json" -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' -d '{}' "http://127.0.0.1:$port/nifi-registry-api/buckets")
[ "$status" = 400 ] || fail "bucket without a name returned HTTP $status, expected 400"

# SIGTERM reaches the bootstrap JVM, which stops the registry before the timeout.
start=$(date +%s)
docker stop --time 90 "$container" >/dev/null
elapsed=$(($(date +%s) - start))
[ "$elapsed" -lt 90 ] || fail 'nifi-registry ignored SIGTERM until the stop timeout'
case $(docker inspect -f '{{.State.ExitCode}}' "$container") in
  0 | 143) ;;
  *)
    docker logs "$container" >&2
    fail 'nifi-registry did not stop cleanly on SIGTERM'
    ;;
esac
docker logs "$container" 2>&1 | grep -q 'Initiating shutdown of Jetty web server' ||
  fail 'bootstrap did not forward SIGTERM as a registry shutdown'

# The bucket survives a restart of the same container filesystem.
docker start "$container" >/dev/null
port=$(docker port "$container" 18080/tcp | awk -F: 'NR == 1 { print $NF }')
wait_ready
curl -fsS "http://127.0.0.1:$port/nifi-registry-api/buckets/$bucket" | grep -q '"name":"verity-smoke"' ||
  fail 'bucket did not persist across a restart'
docker rm -f "$container" >/dev/null

# Negative: an invalid HTTP port must stop the container with the property
# diagnostic instead of serving. The upstream bootstrap reports a failed
# registry start with exit status 0, so the status itself is not asserted.
docker run -d --platform "$platform" --name "$invalid_container" \
  -e NIFI_REGISTRY_WEB_HTTP_PORT=not-a-port "$image" >/dev/null
i=0
while [ "$(docker inspect -f '{{.State.Running}}' "$invalid_container")" = true ]; do
  i=$((i + 1))
  [ "$i" -lt 120 ] || fail 'invalid HTTP port configuration kept running'
  sleep 1
done
docker logs "$invalid_container" 2>&1 |
  grep -q 'nifi.registry.web.http.port must be an integer value' ||
  { docker logs "$invalid_container" >&2; fail 'invalid HTTP port diagnostic is missing'; }
if docker logs "$invalid_container" 2>&1 | grep -q 'Started oejs.Server'; then
  fail 'invalid HTTP port configuration started the web server'
fi

printf 'nifi-registry %s smoke test passed\n' "$expected_version"
