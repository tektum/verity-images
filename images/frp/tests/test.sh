#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# The curl fixture is only an HTTP client; the pinned index is resolved per platform.
fixture_index='docker.io/curlimages/curl:8.14.1@sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b'
label=verity.test=frp-$$
network="verity-frp-network-$$"
server="verity-frp-server-$$"
client="verity-frp-client-$$"
work=$(mktemp -d)
token=verity-frp-smoke-token
dashboard_password=verity-frp-dashboard

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -fv >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  for container in "$server" "$client"; do
    printf '%s logs:\n' "$container" >&2
    docker logs "$container" >&2 2>/dev/null || true
  done
  printf '%s\n' "$1" >&2
  exit 1
}

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/frps"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'

version=$(docker run --rm --network none --read-only "$image" --version)
[ "$version" = "$expected_version" ] ||
  fail "frps version is '$version', expected '$expected_version'"
version=$(docker run --rm --network none --read-only --entrypoint /usr/bin/frpc "$image" --version)
[ "$version" = "$expected_version" ] ||
  fail "frpc version is '$version', expected '$expected_version'"

if docker run --rm --network none --read-only "$image" --definitely-invalid \
  >"$work/invalid" 2>&1; then
  fail 'invalid argument unexpectedly succeeded'
fi
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'invalid argument diagnostic is missing'

mkdir -p "$work/conf" "$work/www"
cat >"$work/conf/frps.toml" <<EOF
bindPort = 7000
auth.method = "token"
auth.token = "$token"
webServer.addr = "0.0.0.0"
webServer.port = 7500
webServer.user = "admin"
webServer.password = "$dashboard_password"
EOF
cat >"$work/conf/frpc.toml" <<EOF
serverAddr = "frps"
serverPort = 7000
auth.method = "token"
auth.token = "$token"

[[proxies]]
name = "verity-static"
type = "tcp"
remotePort = 6000
[proxies.plugin]
type = "static_file"
localPath = "/srv/www"
stripPrefix = "static"
EOF
sed "s/^auth.token = .*/auth.token = \"wrong-token\"/" "$work/conf/frpc.toml" >"$work/conf/frpc-wrong.toml"
printf 'bindPort = "not-a-port"\n' >"$work/conf/frps-invalid.toml"
printf 'verity frp smoke %s\n' "$$" >"$work/www/hello.txt"
chmod -R a+rX "$work"

docker run --rm --network none --read-only -v "$work/conf:/etc/frp:ro" "$image" \
  verify -c /etc/frp/frps.toml >"$work/verify" 2>&1 || fail "frps verify failed: $(cat "$work/verify")"
grep -F 'syntax is ok' "$work/verify" >/dev/null || fail 'frps verify did not accept the config'
if docker run --rm --network none --read-only -v "$work/conf:/etc/frp:ro" "$image" \
  verify -c /etc/frp/frps-invalid.toml >"$work/verify-invalid" 2>&1; then
  fail 'frps accepted an invalid config'
fi
docker run --rm --network none --read-only -v "$work/conf:/etc/frp:ro" \
  --entrypoint /usr/bin/frpc "$image" verify -c /etc/frp/frpc.toml >"$work/verify" 2>&1 ||
  fail "frpc verify failed: $(cat "$work/verify")"

image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
fixture_raw=$(docker buildx imagetools inspect --raw "$fixture_index") ||
  fail "cannot inspect $fixture_index"
[ "sha256:$(printf '%s' "$fixture_raw" | sha256sum | cut -d' ' -f1)" = "${fixture_index#*@}" ] ||
  fail "index digest mismatch for $fixture_index"
fixture_digest=$(printf '%s' "$fixture_raw" | jq -r --arg arch "$image_arch" '
  [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
  | if length == 1 then .[0] else empty end')
case $fixture_digest in
  sha256:*) ;;
  *) fail "no unique linux/$image_arch child in $fixture_index" ;;
esac
fixture=docker.io/curlimages/curl@$fixture_digest
docker pull --quiet --platform "linux/$image_arch" "$fixture" >/dev/null ||
  fail "cannot pull $fixture"

docker network create --label "$label" "$network" >/dev/null
docker run -d --label "$label" --name "$server" --network "$network" --network-alias frps \
  --read-only -v "$work/conf:/etc/frp:ro" "$image" -c /etc/frp/frps.toml >/dev/null

curl_in() {
  docker run --rm --label "$label" --network "$network" "$fixture" -fsS --max-time 5 "$@"
}

attempts=0
until docker logs "$server" 2>&1 | grep -F 'frps started successfully' >/dev/null; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || fail 'frps never started'
  sleep 1
done

# A client with the wrong token must be rejected and exit (loginFailExit defaults to true).
if timeout 60 docker run --rm --label "$label" --network "$network" --read-only \
  -v "$work/conf:/etc/frp:ro" --entrypoint /usr/bin/frpc "$image" \
  -c /etc/frp/frpc-wrong.toml >"$work/wrong" 2>&1; then
  fail 'frpc with a wrong token unexpectedly succeeded'
fi
grep -F 'token in login doesn' "$work/wrong" >/dev/null ||
  fail "wrong token diagnostic is missing: $(cat "$work/wrong")"

docker run -d --label "$label" --name "$client" --network "$network" --read-only \
  -v "$work/conf:/etc/frp:ro" -v "$work/www:/srv/www:ro" \
  --entrypoint /usr/bin/frpc "$image" -c /etc/frp/frpc.toml >/dev/null

attempts=0
until curl_in "http://frps:6000/static/hello.txt" >"$work/body" 2>"$work/curl"; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || fail "proxied file never became reachable: $(cat "$work/curl")"
  sleep 1
done
[ "$(cat "$work/body")" = "verity frp smoke $$" ] ||
  fail "unexpected proxied body: $(cat "$work/body")"
docker logs "$client" 2>&1 | grep -F 'login to server success' >/dev/null ||
  fail 'frpc did not log in'
docker logs "$client" 2>&1 | grep -F '[verity-static] start proxy success' >/dev/null ||
  fail 'frpc did not start the proxy'

curl_in -u "admin:$dashboard_password" http://frps:7500/api/proxy/tcp >"$work/proxies" ||
  fail 'dashboard API request failed'
jq -e '.proxies[] | select(.name == "verity-static" and .status == "online" and .conf.remotePort == 6000)' \
  "$work/proxies" >/dev/null || fail "dashboard does not list the online proxy: $(cat "$work/proxies")"
if curl_in -u "admin:wrong" http://frps:7500/api/proxy/tcp >/dev/null 2>&1; then
  fail 'dashboard accepted a wrong password'
fi
curl_in -u "admin:$dashboard_password" http://frps:7500/static/ >"$work/index" ||
  fail 'embedded dashboard request failed'
grep -F '<div id="app"></div>' "$work/index" >/dev/null ||
  fail 'embedded dashboard index is missing'

# Both processes must stop on SIGTERM well inside the grace period (137 would
# mean docker had to SIGKILL them); frpc first closes its control session.
docker stop --time 10 "$client" >/dev/null
case $(docker inspect --format '{{.State.ExitCode}}' "$client") in
  0 | 143) ;;
  *) fail 'frpc did not stop on SIGTERM' ;;
esac
docker logs "$server" 2>&1 | grep -F 'client exit success' >/dev/null ||
  fail 'frpc did not close its session with frps on SIGTERM'
docker stop --time 10 "$server" >/dev/null
case $(docker inspect --format '{{.State.ExitCode}}' "$server") in
  0 | 143) ;;
  *) fail 'frps did not stop on SIGTERM' ;;
esac

printf 'SMOKE PASS image=%s\n' "$image"
