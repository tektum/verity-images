#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
recipe=$here/../melange.yaml
backend="verity-chp-backend-test-$$"
proxy="verity-chp-proxy-test-$$"
proxy_default="verity-chp-default-test-$$"
network="verity-chp-net-$$"
label="verity-test=configurable-http-proxy"
app=/srv/configurable-http-proxy
work=$(mktemp -d)

# Secrets and the backend's response body are generated per run; nothing is
# stored in the repository.
token() { od -An -N24 -tx1 /dev/urandom | tr -d ' \n'; }
proxy_token=$(token)
file_token=$(token)
marker="chp-backend-$(token)"

# The expected release comes from the recipe, so a version bump needs no edit here.
expected_release=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' "$recipe" | head -n 1)
[ -n "$expected_release" ] || { printf 'package version not found in %s\n' "$recipe" >&2; exit 1; }

cleanup() {
  docker rm -f "$backend" "$proxy" "$proxy_default" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  for container in "$backend" "$proxy" "$proxy_default"; do
    docker logs "$container" >&2 2>&1 || true
  done
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# Every container runs as the image's user with no capabilities and a
# read-only root filesystem.
run() {
  docker run --label "$label" --read-only --cap-drop ALL --security-opt no-new-privileges \
    --tmpfs /tmp:uid=65534,gid=65534,mode=1777 "$@"
}

inspect() { docker image inspect --format "$1" "$image"; }

status() { # FILE [CURL ARGS...] -> HTTP status, body in FILE
  out=$1
  shift
  curl --silent --show-error --max-time 10 --output "$out" --write-out '%{http_code}' "$@" || true
}

published() { # CONTAINER PORT -> host port bound on 127.0.0.1
  docker port "$1" "$2/tcp" | awk -F: 'NR == 1 { print $NF }'
}

wait_api() { # BASE TOKEN
  attempts=0
  until [ "$(status "$work/ready.json" -H "Authorization: token $2" "$1/api/routes" 2>/dev/null)" = 200 ]; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 60 ] || fail "proxy API at $1 did not become ready"
    sleep 1
  done
}

# Upstream image contract (Dockerfile): USER 65534, WORKDIR
# /srv/configurable-http-proxy, chp-docker-entrypoint as ENTRYPOINT and
# configurable-http-proxy on PATH.
test "$(inspect '{{.Config.User}}')" = 65534 || fail 'unexpected OCI user'
test "$(inspect '{{.Config.WorkingDir}}')" = "$app" || fail 'unexpected working directory'
test "$(inspect '{{json .Config.Entrypoint}}')" = "[\"$app/chp-docker-entrypoint\"]" ||
  fail 'entrypoint is not chp-docker-entrypoint'
test "$(inspect '{{json .Config.Cmd}}')" = null || fail 'unexpected default command'

test "$(run --rm --entrypoint id "$image")" = 'uid=65534(nobody) gid=65534(nobody) groups=65534(nobody)' ||
  fail 'container does not run as nobody (65534:65534)'
test "$(run --rm --entrypoint sh "$image" -c 'command -v configurable-http-proxy')" = "$app/bin/configurable-http-proxy" ||
  fail 'configurable-http-proxy is not first on PATH'
# Production dependencies only, and npm is not shipped (upstream uninstalls it).
run --rm --entrypoint sh "$image" -c "
  test -d $app/node_modules/http-proxy-3 || { echo 'http-proxy-3 missing'; exit 1; }
  for dev in jasmine c8 node-fetch ws tmp; do
    test ! -e $app/node_modules/\$dev || { echo \"dev dependency \$dev shipped\"; exit 1; }
  done
  ! command -v npm >/dev/null || { echo 'npm is shipped'; exit 1; }
" || fail 'runtime file set is not production-only'

# Version through the default entrypoint and through the binary the chart runs.
version=$(run --rm "$image" --version) || fail '--version through the entrypoint failed'
test "$version" = "$expected_release" || fail "entrypoint --version printed '$version', wanted $expected_release"
version=$(run --rm --entrypoint configurable-http-proxy "$image" --version) || fail 'configurable-http-proxy --version failed'
test "$version" = "$expected_release" || fail "configurable-http-proxy --version printed '$version', wanted $expected_release"
printf 'version %s\n' "$version"

docker network create "$network" >/dev/null

# The backend is a second container of the image under test on the private
# network, answering every request with this run's marker and the path it saw.
run -d --name "$backend" --network "$network" --network-alias backend -e MARKER="$marker" \
  --entrypoint node "$image" -e '
require("http").createServer((req, res) => {
  res.writeHead(200, { "Content-Type": "text/plain" });
  res.end(process.env.MARKER + " path=" + req.url + "\n");
}).listen(9000, "0.0.0.0", () => console.log("backend listening"));
' >/dev/null

run -d --name "$proxy" --network "$network" -e CONFIGPROXY_AUTH_TOKEN="$proxy_token" \
  -p 127.0.0.1::8000 -p 127.0.0.1::8001 "$image" --api-ip 0.0.0.0 >/dev/null
proxy_port=$(published "$proxy" 8000)
api_port=$(published "$proxy" 8001)
[ -n "$proxy_port" ] && [ -n "$api_port" ] || fail 'proxy ports 8000 and 8001 were not published'
proxy_base="http://127.0.0.1:$proxy_port"
api_base="http://127.0.0.1:$api_port"
wait_api "$api_base" "$proxy_token"

# The REST API rejects missing and wrong tokens.
code=$(status "$work/anon" "$api_base/api/routes")
test "$code" = 403 || fail "GET /api/routes without a token returned $code, wanted 403"
code=$(status "$work/wrong" -H "Authorization: token $(token)" "$api_base/api/routes")
test "$code" = 403 || fail "GET /api/routes with a wrong token returned $code, wanted 403"
code=$(status "$work/anon-post" -X POST -d '{"target": "http://backend:9000"}' "$api_base/api/routes/smoke")
test "$code" = 403 || fail "POST /api/routes/smoke without a token returned $code, wanted 403"
printf 'API without token -> 403, wrong token -> 403\n'

# Add a route and read it back.
code=$(status "$work/post" -X POST -H "Authorization: token $proxy_token" \
  -H 'Content-Type: application/json' -d '{"target": "http://backend:9000"}' "$api_base/api/routes/smoke")
test "$code" = 201 || fail "POST /api/routes/smoke returned $code, wanted 201"
code=$(status "$work/routes.json" -H "Authorization: token $proxy_token" "$api_base/api/routes")
test "$code" = 200 || fail "GET /api/routes returned $code"
jq -e '.["/smoke"].target == "http://backend:9000"' "$work/routes.json" >/dev/null ||
  fail "GET /api/routes does not list /smoke -> http://backend:9000: $(cat "$work/routes.json")"
printf 'GET /api/routes -> %s\n' "$(jq -c 'map_values(.target)' "$work/routes.json")"

# The proxy port forwards the routed path to the backend, path included.
code=$(status "$work/proxied" "$proxy_base/smoke/hello?x=1")
test "$code" = 200 || fail "GET /smoke/hello through the proxy returned $code, wanted 200"
test "$(cat "$work/proxied")" = "$marker path=/smoke/hello?x=1" ||
  fail "proxied response did not come from the backend: $(cat "$work/proxied")"
printf 'GET /smoke/hello -> 200 from backend\n'

# An unrouted path has no default target and gets the built-in 404 page.
code=$(status "$work/unrouted" "$proxy_base/unrouted")
test "$code" = 404 || fail "GET /unrouted returned $code, wanted 404"
grep -F 'No service is registered at this URL' "$work/unrouted" >/dev/null ||
  fail 'unrouted path did not return the built-in 404 page'
if grep -F "$marker" "$work/unrouted" >/dev/null; then fail 'unrouted path reached the backend'; fi
printf 'GET /unrouted -> 404\n'

# Deleting the route stops proxying it.
code=$(status "$work/delete-anon" -X DELETE "$api_base/api/routes/smoke")
test "$code" = 403 || fail "DELETE /api/routes/smoke without a token returned $code, wanted 403"
code=$(status "$work/delete" -X DELETE -H "Authorization: token $proxy_token" "$api_base/api/routes/smoke")
test "$code" = 204 || fail "DELETE /api/routes/smoke returned $code, wanted 204"
code=$(status "$work/routes2.json" -H "Authorization: token $proxy_token" "$api_base/api/routes")
test "$code" = 200 || fail "GET /api/routes after delete returned $code"
jq -e 'has("/smoke") | not' "$work/routes2.json" >/dev/null || fail '/smoke is still listed after DELETE'
code=$(status "$work/deleted" "$proxy_base/smoke/hello")
test "$code" = 404 || fail "GET /smoke/hello after DELETE returned $code, wanted 404"
if grep -F "$marker" "$work/deleted" >/dev/null; then fail 'deleted route still reached the backend'; fi
printf 'DELETE /api/routes/smoke -> 204, /smoke/hello -> 404\n'

# SIGTERM stops the proxy promptly; upstream's handler exits with status 2.
docker stop --time 20 "$proxy" >/dev/null
test "$(docker inspect --format '{{.State.ExitCode}}' "$proxy")" = 2 ||
  fail 'proxy did not exit through its SIGTERM handler'

# Without --api-ip the entrypoint wrapper binds the API to 0.0.0.0, and it reads
# the token from CONFIGPROXY_AUTH_TOKEN_FILE.
printf '%s' "$file_token" >"$work/token"
chmod 644 "$work/token"
run -d --name "$proxy_default" --network "$network" -v "$work/token:/run/secrets/chp-token:ro" \
  -e CONFIGPROXY_AUTH_TOKEN_FILE=/run/secrets/chp-token -p 127.0.0.1::8001 "$image" >/dev/null
api_port=$(published "$proxy_default" 8001)
[ -n "$api_port" ] || fail 'default proxy API port 8001 was not published'
wait_api "http://127.0.0.1:$api_port" "$file_token"
code=$(status "$work/file-wrong" -H "Authorization: token $proxy_token" "http://127.0.0.1:$api_port/api/routes")
test "$code" = 403 || fail "default proxy accepted a token other than the file token ($code)"
printf 'default entrypoint: API on 0.0.0.0:8001 with CONFIGPROXY_AUTH_TOKEN_FILE\n'

printf 'SMOKE PASS image=%s release=%s\n' "$image" "$expected_release"
