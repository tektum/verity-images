#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
name=dapr-sentry
container="verity-$name-test-$$"
cli=/sentry
work=$(mktemp -d)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  docker logs "$container" >&2 2>/dev/null || true
  exit 1
}

expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || fail 'package version not found in melange.yaml'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'OCI user is not 65532'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  "[\"$cli\"]" || fail 'unexpected entrypoint'
case $(docker image inspect --format '{{json .Config.Cmd}}' "$image") in
  null | '[]') ;;
  *) fail 'unexpected default command' ;;
esac
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = / ||
  fail 'unexpected working directory'

# The charts invoke the binary from the root, and the package keeps it in /usr/bin.
docker run --rm --network none --entrypoint /usr/bin/sentry "$image" --help >"$work/help" 2>&1 || true
grep -F -e '--healthz-port' -e '-healthz-port' "$work/help" >/dev/null ||
  { head -n 5 "$work/help" >&2; fail 'sentry help is missing the healthz port flag'; }

if docker run --rm --network none --read-only "$image" --definitely-invalid \
  >"$work/invalid" 2>&1; then
  fail 'unknown flag unexpectedly succeeded'
fi
grep -F -e 'unknown flag: --definitely-invalid' \
  -e 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'unknown flag diagnostic is missing'

wait_http() {
  url=$1
  want=$2
  i=0
  until code=$(curl --silent --output "$work/body" --write-out '%{http_code}' \
    --connect-timeout 1 --max-time 5 "$url") && [ "$code" = "$want" ]; do
    i=$((i + 1))
    [ "$i" -lt 30 ] || fail "$url did not return $want (last: ${code:-none})"
    sleep 1
  done
}

host_port() {
  port=$(docker port "$container" "$1/tcp" | awk -F: 'NR == 1 { print $NF }')
  [ -n "$port" ] || fail "port $1 is not published"
  printf '%s' "$port"
}

stop_clean() {
  docker stop "$container" >/dev/null
  test "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ||
    fail 'did not exit 0 on SIGTERM'
  docker logs "$container" 2>&1 | grep -F "version $expected_version" >/dev/null ||
    fail "startup log does not report version $expected_version"
  docker rm -f "$container" >/dev/null
}

cat >"$work/config.yaml" <<'EOF'
apiVersion: dapr.io/v1alpha1
kind: Configuration
metadata:
  name: daprsystem
spec:
  mtls:
    enabled: true
    workloadCertTTL: 24h
    allowedClockSkew: 15m
EOF
chmod 644 "$work/config.yaml"

# Sentry refuses to start without its configuration.
if docker run --rm --network none --read-only "$image" >"$work/no-config" 2>&1; then
  fail 'sentry started without a configuration'
fi
grep -F "couldn't find config name" "$work/no-config" >/dev/null ||
  fail 'missing configuration diagnostic is missing'

mkdir "$work/creds"
chmod 777 "$work/creds"
docker run --name "$container" -d --read-only --user 65532 \
  -v "$work/creds:/tmp/creds" -v "$work/config.yaml:/tmp/config.yaml:ro" \
  -p 127.0.0.1::8080 "$image" --config /tmp/config.yaml --issuer-credentials /tmp/creds \
  --trust-domain verity.test --healthz-listen-address 0.0.0.0 --healthz-port 8080 >/dev/null
port=$(host_port 8080)
wait_http "http://127.0.0.1:$port/healthz" 200
# A healthy sentry has generated its certificate authority.
for file in ca.crt issuer.crt issuer.key; do
  [ -s "$work/creds/$file" ] || fail "sentry did not write $file"
done
docker logs "$container" 2>&1 | grep -F 'Security is initialized successfully' >/dev/null ||
  fail 'sentry did not report an initialized security layer'
stop_clean
