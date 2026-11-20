#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
label=verity.test=harbor-portal-$$
portal="verity-harbor-portal-$$"
work=$(mktemp -d)

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -fv >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# OCI contract: upstream goharbor/harbor-portal runs nginx as UID 10000 with no
# entrypoint, CMD `nginx -g "daemon off;"`, and SIGQUIT as the stop signal.
[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 10000 ] ||
  fail 'image must run as UID 10000'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = null ] ||
  fail 'image must not set an entrypoint'
[ "$(docker image inspect -f '{{json .Config.Cmd}}' "$image")" = '["nginx","-g","daemon off;"]' ] ||
  fail 'unexpected command'
[ "$(docker image inspect -f '{{.Config.StopSignal}}' "$image")" = SIGQUIT ] ||
  fail 'stop signal must be SIGQUIT'

# start NAME ARGS...: run the portal unprivileged on a read-only root.
start() {
  name=$1
  shift
  docker run -d --label "$label" --name "$name" --read-only --tmpfs /tmp \
    -p 127.0.0.1::8080 "$@" "$image" >/dev/null
  port=$(docker port "$name" 8080/tcp | awk -F: 'NR == 1 { print $NF }')
  [ -n "$port" ] || fail "$name port is not published"
  attempts=0
  until curl --fail --silent --max-time 5 "http://127.0.0.1:$port/" >"$work/index.html"; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 30 ] || { docker logs "$name" >&2; fail "$name did not serve /"; }
    [ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ] || {
      docker logs "$name" >&2
      fail "$name exited"
    }
    sleep 1
  done
}

start "$portal"
grep -F '<title>Harbor</title>' "$work/index.html" >/dev/null || fail 'index.html is not the Harbor portal'
script=$(grep -o 'src="main[^"]*\.js"' "$work/index.html" | head -1 | sed 's/^src="//; s/"$//')
[ -n "$script" ] || fail 'index.html does not reference the Angular main bundle'
curl --fail --silent --max-time 5 "http://127.0.0.1:$port/$script" >"$work/main.js" ||
  fail "main bundle $script is not served"
[ -s "$work/main.js" ] || fail 'main bundle is empty'

# index.html must never be cached; a client-side route loads the app shell.
curl --fail --silent --max-time 5 -D "$work/index.headers" -o /dev/null \
  "http://127.0.0.1:$port/index.html" || fail 'index.html request failed'
grep -i '^Cache-Control: no-store, no-cache, must-revalidate' "$work/index.headers" >/dev/null ||
  fail 'index.html is served without the no-store Cache-Control header'
curl --fail --silent --max-time 5 "http://127.0.0.1:$port/harbor/projects" >"$work/route.html" ||
  fail 'client-side route was not served'
grep -F '<title>Harbor</title>' "$work/route.html" >/dev/null ||
  fail 'client-side route did not fall back to the app shell'

# API explorer and the generated OpenAPI document.
curl --fail --silent --max-time 5 "http://127.0.0.1:$port/swagger.json" >"$work/swagger.json" ||
  fail 'swagger.json is not served'
[ "$(jq -r '.info.title + "|" + .basePath' "$work/swagger.json")" = 'Harbor API|/api/v2.0' ] ||
  fail 'swagger.json is not the Harbor v2.0 API'
curl --fail --silent --max-time 5 "http://127.0.0.1:$port/devcenter-api-2.0" >"$work/devcenter.html" ||
  fail 'API explorer route is not served'
grep -Fi 'swagger' "$work/devcenter.html" >/dev/null || fail 'API explorer route did not load swagger-ui'
gzip=$(curl --silent --max-time 5 -H 'Accept-Encoding: gzip' -o /dev/null -w '%{size_download}' \
  "http://127.0.0.1:$port/swagger.json")
[ "$gzip" -lt "$(wc -c <"$work/swagger.json")" ] || fail 'swagger.json is not gzip encoded'

# Graceful SIGQUIT stop.
docker stop -t 20 "$portal" >/dev/null
[ "$(docker inspect -f '{{.State.ExitCode}}' "$portal")" = 0 ] || {
  docker logs "$portal" >&2
  fail 'nginx did not exit 0 on SIGQUIT'
}

# Harbor deployments mount their own /etc/nginx/nginx.conf.
cat >"$work/nginx.conf" <<'EOF'
worker_processes 1;
pid /tmp/nginx.pid;
events {
    worker_connections 64;
}
http {
    client_body_temp_path /tmp/client_body_temp;
    proxy_temp_path /tmp/proxy_temp;
    fastcgi_temp_path /tmp/fastcgi_temp;
    uwsgi_temp_path /tmp/uwsgi_temp;
    scgi_temp_path /tmp/scgi_temp;
    server {
        listen 8080;
        root /usr/share/nginx/html;
        include /etc/nginx/mime.types;
        location = /mounted { return 200 "mounted config\n"; }
        location / { try_files $uri $uri/ /index.html; }
    }
}
EOF
chmod a+r "$work/nginx.conf"
start "$portal-mounted" -v "$work/nginx.conf:/etc/nginx/nginx.conf:ro"
[ "$(curl --fail --silent --max-time 5 "http://127.0.0.1:$port/mounted")" = 'mounted config' ] ||
  fail 'mounted nginx.conf was not used'
curl --fail --silent --max-time 5 -o /dev/null -w '%{content_type}' "http://127.0.0.1:$port/$script" |
  grep -E '^(application|text)/javascript' >/dev/null || fail 'mime.types is missing'

# Negative: an invalid mounted configuration fails nginx startup.
printf 'events {}\nhttp { server { listen 8080; bogus_directive on; } }\n' >"$work/bad.conf"
chmod a+r "$work/bad.conf"
if docker run --rm --label "$label" --read-only --tmpfs /tmp \
  -v "$work/bad.conf:/etc/nginx/nginx.conf:ro" "$image" >"$work/bad.log" 2>&1; then
  fail 'nginx started with an invalid configuration'
fi
grep -F 'unknown directive "bogus_directive"' "$work/bad.log" >/dev/null || {
  cat "$work/bad.log" >&2
  fail 'invalid configuration was not reported'
}

printf 'SMOKE PASS image=%s\n' "$image"
