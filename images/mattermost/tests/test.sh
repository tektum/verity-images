#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml" | head -n 1)
postgres_index='docker.io/library/postgres:17-alpine@sha256:742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193'
backend="verity-mattermost-postgres-$$"
app="verity-mattermost-app-$$"
invalid="verity-mattermost-invalid-$$"
network="verity-mattermost-network-$$"
tmp=$(mktemp -d)

cleanup() {
  docker rm -f "$app" "$invalid" "$backend" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -n "$expected_version" ] || fail 'package version not found in melange.yaml'

# OCI contract, mirroring upstream's image: uid 2000, /mattermost workdir.
[ "$(docker image inspect "$image" --format '{{.Config.User}}')" = 2000 ] ||
  fail 'image user is not 2000'
[ "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = \
  '["/mattermost/bin/mattermost"]' ] || fail 'unexpected image entrypoint'
[ "$(docker image inspect "$image" --format '{{.Config.WorkingDir}}')" = /mattermost ] ||
  fail 'image working directory is not /mattermost'

# Filesystem layout: upstream's directory tree, Team Edition only. The image has
# no shell, so list it from an exported container.
docker create --name "$app" "$image" >/dev/null
docker export "$app" | tar -tf - | sed 's|/$||' >"$tmp/files"
docker rm "$app" >/dev/null
for path in mattermost/bin/mattermost mattermost/config/config.json \
  mattermost/client/root.html mattermost/client/manifest.json \
  mattermost/i18n/en.json mattermost/templates mattermost/fonts \
  mattermost/LICENSE.txt mattermost/NOTICE.txt \
  mattermost/data mattermost/logs mattermost/plugins mattermost/client/plugins \
  usr/bin/pdftotext usr/bin/unrtf usr/bin/tidy etc/mime.types; do
  grep -Fx "$path" "$tmp/files" >/dev/null || fail "missing $path"
done
[ "$(grep -c '^mattermost/bin/' "$tmp/files")" -eq 1 ] ||
  fail 'unexpected binaries next to mattermost in /mattermost/bin'
if grep -E -i 'enterprise|prepackaged_plugins|MIT-COMPILED-LICENSE' "$tmp/files" >"$tmp/ee"; then
  cat "$tmp/ee" >&2
  fail 'image ships Enterprise or prepackaged plugin content'
fi
if grep -E '^(bin/sh|usr/bin/sh|bin/busybox|usr/bin/busybox)$' "$tmp/files" >/dev/null; then
  fail 'image unexpectedly ships a shell'
fi

# `mattermost version` must report this release as a Team Edition build.
docker run --rm "$image" version >"$tmp/version" 2>&1 || {
  cat "$tmp/version" >&2
  fail 'mattermost version failed'
}
grep -Fx "Version: $expected_version" "$tmp/version" >/dev/null ||
  fail "version output does not report $expected_version"
grep -Fx "Build Number: $expected_version" "$tmp/version" >/dev/null ||
  fail 'version output has an unexpected build number'
grep -Fx 'Build Enterprise Ready: false' "$tmp/version" >/dev/null || {
  cat "$tmp/version" >&2
  fail 'mattermost version does not report a Team Edition build'
}

# A classic Docker image store cannot bind the index digest to a second
# platform's image, so pull the helper by its own per-platform child digest.
# The index bytes are verified against the pinned digest before a child is
# chosen, which keeps the pin authoritative.
image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
postgres_raw=$(docker buildx imagetools inspect --raw "$postgres_index") ||
  fail 'cannot inspect helper image index'
[ "sha256:$(printf '%s' "$postgres_raw" | sha256sum | cut -d' ' -f1)" = "${postgres_index#*@}" ] ||
  fail 'helper image index digest mismatch'
postgres_digest=$(printf '%s' "$postgres_raw" |
  jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') ||
  fail 'cannot resolve helper image digest'
case $postgres_digest in
  sha256:*) ;;
  *) fail "no unique linux/$image_arch helper image in $postgres_index" ;;
esac
postgres=docker.io/library/postgres@$postgres_digest
docker pull --quiet --platform "linux/$image_arch" "$postgres" >/dev/null ||
  fail 'cannot pull helper image'

docker network create "$network" >/dev/null
docker run --name "$backend" -d --network "$network" --network-alias postgres \
  -e POSTGRES_USER=mmuser \
  -e POSTGRES_PASSWORD=smoke \
  -e POSTGRES_DB=mattermost \
  "$postgres" >/dev/null

attempts=0
until docker exec "$backend" pg_isready -U mmuser -d mattermost >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || {
    docker logs "$backend" >&2
    fail 'postgres did not become ready'
  }
  sleep 1
done

dsn='postgres://mmuser:smoke@postgres:5432/mattermost?sslmode=disable&connect_timeout=10'

start_app() {
  docker start "$app" >/dev/null
  port=$(docker port "$app" 8065/tcp | awk -F: 'NR == 1 { print $2 }')
  [ -n "$port" ] || fail 'port 8065 is not published'
  attempts=0
  until curl --fail --silent --connect-timeout 1 --max-time 5 \
    "http://127.0.0.1:$port/api/v4/system/ping" >"$tmp/ping" 2>/dev/null; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 180 ] || {
      docker logs "$app" >&2
      fail 'mattermost did not answer /api/v4/system/ping'
    }
    [ "$(docker inspect -f '{{.State.Running}}' "$app")" = true ] || {
      docker logs "$app" >&2
      fail 'mattermost exited before it became ready'
    }
    sleep 1
  done
  [ "$(jq -r .status "$tmp/ping")" = OK ] || {
    cat "$tmp/ping" >&2
    fail 'ping status is not OK'
  }
}

docker create --name "$app" --network "$network" \
  -e MM_SQLSETTINGS_DRIVERNAME=postgres \
  -e "MM_SQLSETTINGS_DATASOURCE=$dsn" \
  -p 127.0.0.1::8065 \
  "$image" >/dev/null
start_app

# The server answers with the webapp built from source, and the client config
# reports a Team Edition build.
curl --fail --silent --max-time 10 "http://127.0.0.1:$port/" >"$tmp/root.html" ||
  fail 'GET / failed'
grep -F '<title>Mattermost</title>' "$tmp/root.html" >/dev/null ||
  fail 'GET / did not serve the Mattermost webapp'
script=$(grep -o 'src="/static/[^"]*\.js"' "$tmp/root.html" | head -n 1 |
  sed 's/^src="//; s/"$//')
[ -n "$script" ] || fail 'root.html references no webapp script'
curl --fail --silent --max-time 10 -o "$tmp/main.js" -w '%{content_type}' \
  "http://127.0.0.1:$port$script" >"$tmp/script-type" || fail "GET $script failed"
grep -F javascript "$tmp/script-type" >/dev/null || fail "$script is not JavaScript"
[ -s "$tmp/main.js" ] || fail "$script is empty"
curl --fail --silent --max-time 10 \
  "http://127.0.0.1:$port/api/v4/config/client?format=old" >"$tmp/client.json" ||
  fail 'client config request failed'
[ "$(jq -r .BuildEnterpriseReady "$tmp/client.json")" = false ] ||
  fail 'client config does not report a Team Edition build'
[ "$(jq -r .Version "$tmp/client.json")" = "$expected_version" ] ||
  fail 'client config reports an unexpected version'

# State lives in PostgreSQL: a user created before a restart can sign in after.
curl --fail --silent --max-time 10 -H 'Content-Type: application/json' \
  -d '{"email":"smoke@example.com","username":"smoke","password":"Verity-Smoke-Password-1"}' \
  "http://127.0.0.1:$port/api/v4/users" >"$tmp/user.json" || fail 'user creation failed'
[ "$(jq -r .username "$tmp/user.json")" = smoke ] || fail 'created user has the wrong name'

docker stop "$app" >/dev/null
[ "$(docker inspect -f '{{.State.ExitCode}}' "$app")" = 0 ] || {
  docker logs "$app" >&2
  fail 'mattermost did not exit cleanly on SIGTERM'
}
start_app
curl --fail --silent --max-time 10 -D "$tmp/login.headers" -o /dev/null \
  -H 'Content-Type: application/json' \
  -d '{"login_id":"smoke","password":"Verity-Smoke-Password-1"}' \
  "http://127.0.0.1:$port/api/v4/users/login" || fail 'login after restart failed'
grep -i '^token: ' "$tmp/login.headers" >/dev/null || fail 'login returned no session token'

# Negative: a DSN with the wrong credentials must stop the server, not leave it
# running without a database.
docker run --name "$invalid" --network "$network" \
  -e MM_SQLSETTINGS_DRIVERNAME=postgres \
  -e 'MM_SQLSETTINGS_DATASOURCE=postgres://mmuser:wrong@postgres:5432/mattermost?sslmode=disable&connect_timeout=5' \
  "$image" >"$tmp/invalid.log" 2>&1 &
invalid_pid=$!
attempts=0
while [ "$(docker inspect -f '{{.State.Status}}' "$invalid" 2>/dev/null || echo created)" != exited ]; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 180 ] || fail 'server kept running with an invalid DSN'
  sleep 1
done
wait "$invalid_pid" || true
[ "$(docker inspect -f '{{.State.ExitCode}}' "$invalid")" != 0 ] ||
  fail 'server exited 0 with an invalid DSN'
grep -F 'password authentication failed' "$tmp/invalid.log" >/dev/null || {
  cat "$tmp/invalid.log" >&2
  fail 'invalid DSN failure does not name the authentication error'
}

printf 'SMOKE PASS image=%s\n' "$image"
