#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*- mitmproxy=\([0-9][0-9.]*\)-r[0-9][0-9]*$/\1/p' \
  "$(dirname "$0")/../apko.yaml")
[ -n "$expected_version" ] || { printf 'mitmproxy package version not found\n' >&2; exit 1; }

suffix=$$-$(date +%s)
net=verity-mitmproxy-$suffix
server=verity-mitmproxy-origin-$suffix
proxy=verity-mitmproxy-proxy-$suffix
work=$(mktemp -d)
cleanup() {
  docker rm -f "$server" "$proxy" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
mkdir -p "$work/site" "$work/flows"
printf 'verity-mitmproxy-origin\n' >"$work/site/hello.txt"
chmod -R a+rX "$work"
chmod 0777 "$work/flows"

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

user=$(docker image inspect --format '{{.Config.User}}' "$image")
[ "$user" = 65532 ] || fail "unexpected user: $user"
entrypoint=$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")
[ "$entrypoint" = '["/usr/bin/mitmdump"]' ] || fail "unexpected entrypoint: $entrypoint"
workdir=$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")
[ "$workdir" = /home/nonroot ] || fail "unexpected working directory: $workdir"

version=$(docker run --rm "$image" --version)
printf '%s\n' "$version" | grep -qx "Mitmproxy: ${expected_version}" ||
  fail "unexpected mitmproxy version: $version"

if docker run --rm "$image" --verity-unknown-option >"$work/bad-option.log" 2>&1; then
  fail 'unknown option unexpectedly succeeded'
fi
grep -q 'unrecognized arguments' "$work/bad-option.log" ||
  fail "unknown option error missing: $(cat "$work/bad-option.log")"

docker network create "$net" >/dev/null

# Local origin server, run from the image's own Python runtime.
docker run -d --name "$server" --network "$net" --network-alias origin -v "$work/site:/site:ro" -w /site \
  --entrypoint /usr/bin/python3.13 "$image" -m http.server 8000 --bind 0.0.0.0 >/dev/null

docker run -d --name "$proxy" --network "$net" --network-alias proxy -v "$work/flows:/flows" "$image" \
  --listen-host 0.0.0.0 --listen-port 8080 --save-stream-file /flows/capture.mitm \
  --set flow_detail=1 >/dev/null

client() {
  docker run --rm --network "$net" --entrypoint /usr/bin/python3.13 "$image" -c '
import sys, urllib.error, urllib.request
opener = urllib.request.build_opener(urllib.request.ProxyHandler({"http": "http://proxy:8080"}))
try:
    with opener.open(sys.argv[1], timeout=5) as response:
        print(response.status)
        sys.stdout.write(response.read().decode())
except urllib.error.HTTPError as error:
    print(error.code)
' "$1"
}

ready=false
for _ in $(seq 1 30); do
  if body=$(client "http://origin:8000/hello.txt" 2>"$work/client.err"); then
    ready=true
    break
  fi
  sleep 1
done
[ "$ready" = true ] || {
  docker logs "$proxy" >&2 || true
  fail "proxy never served the origin: $(cat "$work/client.err")"
}
[ "$body" = "200
verity-mitmproxy-origin" ] || fail "unexpected proxied response: $body"

status=$(client "http://verity-missing-origin.invalid/" 2>"$work/client.err") ||
  fail "unreachable origin client failed: $(cat "$work/client.err")"
[ "$(printf '%s\n' "$status" | head -n1)" = 502 ] ||
  fail "unreachable origin returned: $status"

# The CA is generated in the writable home directory on first start.
docker exec "$proxy" /usr/bin/python3.13 -c \
  'import os; assert os.path.getsize("/home/nonroot/.mitmproxy/mitmproxy-ca-cert.pem") > 0' ||
  fail 'mitmproxy CA certificate was not generated'

docker logs "$proxy" >"$work/proxy.log" 2>&1
grep -q "GET http://origin:8000/hello.txt" "$work/proxy.log" ||
  fail "proxy log missing captured request: $(cat "$work/proxy.log")"

docker stop -t 10 "$proxy" >/dev/null
exit_code=$(docker inspect --format '{{.State.ExitCode}}' "$proxy")
[ "$exit_code" = 0 ] || fail "mitmdump exited $exit_code on SIGTERM"

replay=$(docker run --rm -v "$work/flows:/flows:ro" "$image" -n -r /flows/capture.mitm \
  --set flow_detail=1 2>&1) || fail "reading captured flows failed: $replay"
printf '%s\n' "$replay" | grep -q "GET http://origin:8000/hello.txt" ||
  fail "capture file missing request: $replay"
printf '%s\n' "$replay" | grep -q '200 OK' ||
  fail "capture file missing 200 response: $replay"

printf 'SMOKE PASS version=%s\n' "$expected_version"
