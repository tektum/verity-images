#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-kiali-test-$$"
copy="verity-kiali-copy-$$"
tmp=$(mktemp -d)

fail() {
  docker logs "$container" >&2 2>&1 || true
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker rm -f "$copy" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 1000 ] \
  || fail 'image user is not 1000'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/opt/kiali/kiali"]' ] \
  || fail 'unexpected image entrypoint'
[ "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /opt/kiali ] \
  || fail 'unexpected working directory'
docker run --rm "$image" --help 2>&1 | grep -F 'console for Istio service mesh' >/dev/null \
  || fail 'kiali --help output was unexpected'

# The release version is stamped into the binary with -X ldflags.
docker create --name "$copy" "$image" >/dev/null
docker cp "$copy:/opt/kiali/kiali" "$tmp/kiali"
grep -aE 'v2\.34\.[0-9]+' "$tmp/kiali" >/dev/null || fail 'kiali binary does not carry the 2.34 version'

# Negative case: an invalid configuration must exit non-zero with a readable error.
if docker run --rm "$image" >"$tmp/invalid.log" 2>&1; then
  fail 'kiali started without a session signing key'
fi
grep -F 'signing key for sessions must be 16, 24 or 32 bytes length' "$tmp/invalid.log" >/dev/null \
  || { cat "$tmp/invalid.log" >&2; fail 'invalid configuration error was not readable'; }

# Negative case: a valid configuration outside a cluster must report that it
# has no Kubernetes configuration instead of starting.
cat >"$tmp/config.yaml" <<'YAML'
auth:
  strategy: anonymous
login_token:
  signing_key: "0123456789abcdef0123456789abcdef"
YAML
chmod 644 "$tmp/config.yaml"
if docker run --rm -v "$tmp/config.yaml:/tmp/config.yaml:ro" "$image" \
  -c /tmp/config.yaml >"$tmp/nocluster.log" 2>&1; then
  fail 'kiali started without a Kubernetes configuration'
fi
grep -F 'no configuration has been provided' "$tmp/nocluster.log" >/dev/null \
  || { cat "$tmp/nocluster.log" >&2; fail 'missing cluster error was not readable'; }

# Run the server against an empty offline data set, which needs no cluster.
mkdir "$tmp/offline"
chmod 755 "$tmp/offline"
docker run --name "$container" -d --read-only --tmpfs /tmp:uid=1000,gid=1000,mode=1777 \
  -v "$tmp/offline:/offline:ro" \
  -p 127.0.0.1::20001 \
  "$image" run offline -d /offline -w >/dev/null
port=$(docker port "$container" 20001/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || fail 'kiali port was not published'
base="http://127.0.0.1:$port"

attempt=0
until curl --fail --silent --connect-timeout 1 --max-time 5 "$base/healthz" >/dev/null; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 60 ] || fail 'kiali did not become healthy'
  sleep 1
done

status=$(curl --fail --silent --max-time 5 "$base/api/status") || fail 'status API request failed'
printf '%s' "$status" | grep -F '"Kiali state": "running"' >/dev/null \
  || { printf '%s\n' "$status" >&2; fail 'status API did not report a running Kiali'; }
curl --fail --silent --max-time 5 "$base/api/auth/info" | grep -F '"strategy":"anonymous"' >/dev/null \
  || fail 'auth info did not report the anonymous strategy'
curl --fail --silent --max-time 5 "$base/" | grep -Fi '<html' >/dev/null \
  || fail 'embedded web UI was not served'

# SIGTERM must stop the server cleanly.
docker stop --timeout 30 "$container" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ] \
  || fail 'kiali did not exit cleanly on SIGTERM'
