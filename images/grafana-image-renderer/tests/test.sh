#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-renderer-test-$$"
tmp=$(mktemp -d)
server_pid=

fail() {
  docker logs "$container" >&2 2>&1 || true
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  [ -z "$server_pid" ] || kill "$server_pid" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] \
  || fail 'image user is not 65532'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/sbin/tini","--","/usr/bin/grafana-image-renderer"]' ] \
  || fail 'unexpected image entrypoint'
[ "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["server"]' ] \
  || fail 'unexpected image command'

# Chromium needs fonts for the scripts Grafana dashboards commonly contain.
for lang in ja zh-cn ko th km; do
  count=$(docker run --rm --entrypoint /usr/bin/fc-list "$image" ":lang=$lang" family | wc -l)
  [ "$count" -gt 0 ] || fail "no installed font covers language $lang"
done

# Negative case: an unusable listen address must exit non-zero with a readable error.
if docker run --rm "$image" server --server.addr=not-an-address >"$tmp/invalid.log" 2>&1; then
  fail 'renderer accepted an invalid listen address'
fi
grep -F 'missing port in address' "$tmp/invalid.log" >/dev/null \
  || { cat "$tmp/invalid.log" >&2; fail 'invalid listen address error was not readable'; }

# A local page to render. The renderer only accepts http and https URLs.
mkdir "$tmp/site"
cat >"$tmp/site/index.html" <<'HTML'
<!doctype html>
<html><head><meta charset="utf-8"><title>verity</title></head>
<body style="background:#fff;font-size:28px"><h1>verity renderer</h1>
<p>Latin text</p><p>&#x65E5;&#x672C;&#x8A9E; &#x4E2D;&#x6587; &#xD55C;&#xAD6D;&#xC5B4;</p><p>&#xE20;&#xE32;&#xE29;&#xE32;&#xE44;&#xE17;&#xE22;</p><p>&#x1797;&#x17B6;&#x179F;&#x17B6;&#x1781;&#x17D2;&#x1798;&#x17C2;&#x179A;</p></body></html>
HTML
site_port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("", 0)); print(s.getsockname()[1])')
python3 -m http.server "$site_port" --bind 0.0.0.0 --directory "$tmp/site" >/dev/null 2>&1 &
server_pid=$!

docker run --name "$container" -d --read-only \
  --tmpfs /tmp:uid=65532,gid=65532,mode=1777 \
  --tmpfs /home/nonroot:uid=65532,gid=65532,mode=1777 \
  --add-host host.docker.internal:host-gateway \
  -p 127.0.0.1::8081 \
  "$image" >/dev/null
port=$(docker port "$container" 8081/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || fail 'renderer port was not published'
base="http://127.0.0.1:$port"

attempt=0
until curl --fail --silent --connect-timeout 1 --max-time 5 "$base/healthz" >/dev/null; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 60 ] || fail 'renderer did not become healthy'
  sleep 1
done
attempt=0
until curl --fail --silent --max-time 2 "http://127.0.0.1:$site_port/index.html" >/dev/null; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 30 ] || fail 'local page server did not start'
  sleep 1
done

curl --fail --silent --max-time 5 "$base/render/version" | grep -E '"version": *"[0-9]+\.[0-9]+\.[0-9]+"' >/dev/null \
  || fail 'render version response was unexpected'
curl --fail --silent --max-time 60 "$base/version" | grep -F 'browser Chromium' >/dev/null \
  || fail 'renderer could not start its browser'

# Requests without the auth token are refused.
status=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 \
  "$base/render?url=http%3A%2F%2Fhost.docker.internal%3A$site_port%2Findex.html")
[ "$status" = 401 ] || fail "unauthenticated render returned $status instead of 401"

# Render the local page to a PNG through Chromium.
curl --fail --silent --show-error --max-time 120 -H 'X-Auth-Token: -' \
  --output "$tmp/render.png" \
  "$base/render?url=http%3A%2F%2Fhost.docker.internal%3A$site_port%2Findex.html&width=600&height=300&encoding=png" \
  || fail 'render request failed'
magic=$(od -An -tx1 -N8 "$tmp/render.png" | tr -d ' \n')
[ "$magic" = 89504e470d0a1a0a ] || fail "rendered output is not a PNG (magic $magic)"
[ "$(wc -c <"$tmp/render.png")" -gt 5000 ] || fail 'rendered PNG is implausibly small'

# SIGTERM must stop the service cleanly.
docker stop --timeout 30 "$container" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ] \
  || fail 'renderer did not exit cleanly on SIGTERM'
