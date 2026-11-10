#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-vmauth-test-$$"
tmp=$(mktemp -d)

fail() {
  docker logs "$container" >&2 2>&1 || true
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  [ -z "${backend_pid:-}" ] || kill "$backend_pid" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 10001 ] \
  || fail 'image user is not 10001'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/vmauth"]' ] \
  || fail 'unexpected image entrypoint'
docker run --rm "$image" -version 2>&1 | grep -F 'vmauth-tags-v1.' >/dev/null \
  || fail 'vmauth version check failed'

# The backend answers every request with a fixed body, so a proxied response
# proves vmauth authenticated the caller and forwarded the request.
cat >"$tmp/backend.py" <<'PY'
import http.server
import sys

BODY = b"verity-backend-ok\n"

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(BODY)))
        self.end_headers()
        self.wfile.write(BODY)

    def log_message(self, *args):
        pass

http.server.HTTPServer(("0.0.0.0", int(sys.argv[1])), Handler).serve_forever()
PY
backend_port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("", 0)); print(s.getsockname()[1])')
python3 "$tmp/backend.py" "$backend_port" &
backend_pid=$!

cat >"$tmp/auth.yml" <<YML
users:
  - bearer_token: verity-smoke-token
    url_prefix: http://host.docker.internal:$backend_port/
YML
chmod 755 "$tmp"
chmod 644 "$tmp/auth.yml"

docker run --name "$container" -d --read-only \
  --add-host host.docker.internal:host-gateway \
  -v "$tmp/auth.yml:/etc/vmauth/auth.yml:ro" -p 127.0.0.1::8427 "$image" \
  -auth.config=/etc/vmauth/auth.yml >/dev/null
port=$(docker port "$container" 8427/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || fail 'port 8427 was not published'
attempt=0
until response=$(curl --fail --silent --connect-timeout 1 --max-time 5 "http://127.0.0.1:$port/health"); do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 30 ] || fail 'vmauth did not become healthy'
  sleep 1
done
[ "$response" = OK ] || fail 'health response was not OK'

status=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 "http://127.0.0.1:$port/anything")
[ "$status" = 401 ] || fail "request without credentials returned $status instead of 401"
status=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 \
  -H 'Authorization: Bearer wrong-token' "http://127.0.0.1:$port/anything")
[ "$status" = 401 ] || fail "request with a wrong token returned $status instead of 401"
body=$(curl --fail --silent --show-error --max-time 5 \
  -H 'Authorization: Bearer verity-smoke-token' "http://127.0.0.1:$port/anything")
[ "$body" = verity-backend-ok ] || fail 'authenticated request was not proxied to the backend'

docker stop --time 30 "$container" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ] \
  || fail 'vmauth did not stop cleanly'
docker rm "$container" >/dev/null

# An invalid auth config must fail startup with a readable error.
printf 'users:\n  - bearer_token: broken\n' >"$tmp/broken.yml"
chmod 644 "$tmp/broken.yml"
if broken=$(docker run --rm -v "$tmp/broken.yml:/etc/vmauth/auth.yml:ro" "$image" \
  -auth.config=/etc/vmauth/auth.yml 2>&1); then
  fail 'invalid auth config unexpectedly succeeded'
fi
printf '%s' "$broken" | grep -F 'fatal' | grep -F 'url_prefix' >/dev/null \
  || fail 'invalid auth config did not return a readable error'

if invalid=$(docker run --rm "$image" -no-such-flag 2>&1); then
  fail 'invalid flag unexpectedly succeeded'
fi
printf '%s' "$invalid" | grep -Fi 'flag provided but not defined' >/dev/null \
  || fail 'invalid flag did not return a readable error'

printf 'SMOKE PASS image=%s\n' "$image"
