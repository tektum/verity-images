#!/bin/sh
# Smoke test: run a local speedtest server stub and the speedtest-go client
# against it on an internal Docker network with no external route.
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(cd "$(dirname "$0")" && pwd)
config="$here/../apko.yaml"
version=$(sed -n 's/^    - speedtest-go=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
stub_image=docker.io/library/python:3.13-alpine@sha256:9ef1a599f863231c3d91e941389bfdc4a2d6070557243d54df1a4e57015b960e
id=$$
network="verity-speedtest-go-$id"
server="verity-speedtest-go-srv-$id"
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  docker logs "$server" 2>&1 | tail -n 20 >&2 || true
  exit 1
}

cleanup() {
  docker rm -f "$server" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail 'could not read the pinned speedtest-go version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/speedtest-go"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

docker run --rm --network none "$image" --version >"$work/version" 2>&1 ||
  fail 'version failed'
grep -F "speedtest-go v$version" "$work/version" >/dev/null ||
  fail "version does not report $version: $(cat "$work/version")"

rc=0
docker run --rm --network none "$image" --definitely-invalid >"$work/invalid" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'unknown long flag' "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"

# Throwaway CA and server certificate so the client's user-info lookup is
# answered by the local stub instead of speedtest.net.
mkdir -p "$work/certs"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=verity-speedtest-test-ca \
  -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign \
  -keyout "$work/certs/ca.key" -out "$work/certs/ca.pem" >/dev/null 2>&1 ||
  fail 'could not create test CA'
openssl req -newkey rsa:2048 -nodes -subj /CN=www.speedtest.net \
  -keyout "$work/certs/server.key" -out "$work/certs/server.csr" >/dev/null 2>&1 ||
  fail 'could not create server key'
printf 'subjectAltName=DNS:www.speedtest.net\nextendedKeyUsage=serverAuth\n' >"$work/certs/ext"
openssl x509 -req -in "$work/certs/server.csr" -CA "$work/certs/ca.pem" \
  -CAkey "$work/certs/ca.key" -CAcreateserial -days 1 -extfile "$work/certs/ext" \
  -out "$work/certs/server.pem" >/dev/null 2>&1 || fail 'could not sign server certificate'
chmod 755 "$work/certs"
chmod 644 "$work/certs"/*

# --internal: no external route, so nothing can reach the real internet.
docker network create --internal "$network" >/dev/null

docker run -d --name "$server" --network "$network" --network-alias www.speedtest.net \
  -v "$work/certs:/certs:ro" -v "$here/speedtest_stub.py:/stub.py:ro" \
  "$stub_image" python -u /stub.py >/dev/null
ready=false
i=0
while [ "$i" -lt 30 ]; do
  if docker logs "$server" 2>&1 | grep -F 'STUB READY' >/dev/null; then
    ready=true
    break
  fi
  i=$((i + 1))
  sleep 1
done
"$ready" || fail 'local speedtest stub did not start'

client() {
  docker run --rm --network "$network" --read-only --cap-drop=ALL \
    --tmpfs /tmp:rw,mode=1777 -e SSL_CERT_FILE=/certs/ca.pem \
    -v "$work/certs/ca.pem:/certs/ca.pem:ro" "$image" "$@"
}

# Negative: the default image trust store must reject the stub's private CA.
rc=0
docker run --rm --network "$network" "$image" \
  --custom-url="http://$server:8080/speedtest/upload.php" --json >"$work/untrusted" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'untrusted user-info endpoint unexpectedly succeeded'
grep -F 'certificate' "$work/untrusted" >/dev/null ||
  fail "untrusted certificate diagnostic is missing: $(cat "$work/untrusted")"

# Negative: an unreachable custom server must not report a result.
rc=0
client --custom-url="http://verity-missing-$id:8080/speedtest/upload.php" --json \
  >"$work/missing" 2>&1 || rc=$?
grep -E '"dl_speed":[1-9]' "$work/missing" >/dev/null &&
  fail "unreachable server reported a speed: $(cat "$work/missing")"
[ "$rc" -ne 0 ] || grep -Ei 'error|fail|no such host' "$work/missing" >/dev/null ||
  fail "unreachable server produced no diagnostic: $(cat "$work/missing")"

# Real run: ping, download, and upload against the local server.
client --custom-url="http://$server:8080/speedtest/upload.php" --json >"$work/result" 2>&1 ||
  fail "speedtest against local server failed: $(cat "$work/result")"
result=$(cat "$work/result")
printf '%s\n' "$result" | grep -F '"Isp":"Verity Local Stub"' >/dev/null ||
  fail "user info not served by local stub: $result"
printf '%s\n' "$result" | grep -F "\"host\":\"$server:8080\"" >/dev/null ||
  fail "result is not for the local server: $result"
printf '%s\n' "$result" | grep -F '"id":"Custom"' >/dev/null ||
  fail "result is not for the custom server: $result"
printf '%s\n' "$result" | grep -E '"latency":[1-9][0-9]*' >/dev/null ||
  fail "no latency measured: $result"
printf '%s\n' "$result" | grep -E '"dl_speed":[1-9]' >/dev/null ||
  fail "no download speed measured: $result"
printf '%s\n' "$result" | grep -E '"ul_speed":[1-9]' >/dev/null ||
  fail "no upload speed measured: $result"

logs=$(docker logs "$server" 2>&1)
printf '%s\n' "$logs" | grep -E '"GET /speedtest-config\.php' >/dev/null ||
  fail 'stub did not serve user info'
printf '%s\n' "$logs" | grep -E '"GET /speedtest/latency\.txt' >/dev/null ||
  fail 'stub did not serve latency probes'
printf '%s\n' "$logs" | grep -E '"GET /speedtest/random[0-9]+x[0-9]+\.jpg' >/dev/null ||
  fail 'stub did not serve download payloads'
printf '%s\n' "$logs" | grep -E '"POST /speedtest/upload\.php' >/dev/null ||
  fail 'stub did not receive uploads'

printf 'SMOKE PASS\n'
