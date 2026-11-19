#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE [FLAVOR]}
flavor=${2:-plain}
here=$(cd "$(dirname "$0")" && pwd)
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' "$here/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
name=verity-parseable-$$
volume=verity-parseable-data-$$
user=verity
# Random per run; never a shipped default.
password=$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')
stream=smoke
marker=verity-parseable-smoke-$$
work=$(mktemp -d)

cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  docker logs "$name" 2>&1 | tail -n 40 >&2 || true
  exit 1
}

case $flavor in plain) ;; *) fail "unsupported flavor $flavor" ;; esac

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/parseable"]' ] ||
  fail 'unexpected entrypoint'
[ "$(docker image inspect -f '{{json .Config.Cmd}}' "$image")" = '["local-store"]' ] ||
  fail 'unexpected command'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /parseable ] ||
  fail 'unexpected working directory'
docker run --rm "$image" --version >"$work/version.txt" 2>&1 || fail '--version failed'
grep -qF "$expected_version" "$work/version.txt" ||
  { cat "$work/version.txt" >&2; fail "version is not $expected_version"; }

start_server() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" -p 127.0.0.1::8000 -v "$volume:/parseable" \
    -e P_USERNAME="$user" -e P_PASSWORD="$password" \
    -e P_CHECK_UPDATE=false -e P_SEND_ANONYMOUS_USAGE_DATA=false \
    "$image" >/dev/null
  port=$(docker port "$name" 8000/tcp | awk -F: 'NR == 1 { print $2 }')
  [ -n "$port" ] || fail 'port 8000 is not published'
  url=http://127.0.0.1:$port
  i=0
  until code=$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --connect-timeout 1 --max-time 5 "$url/api/v1/liveness") && [ "$code" = 200 ]; do
    i=$((i + 1))
    [ "$i" -lt 120 ] || fail "liveness did not return 200 (last: ${code:-none})"
    [ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ] || fail 'server exited during startup'
    sleep 1
  done
  readiness=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 \
    "$url/api/v1/readiness") || fail 'readiness request failed'
  [ "$readiness" = 200 ] || fail "readiness returned $readiness"
}

api() {
  # api METHOD PATH [CURL_ARGS...]: authenticated request, prints the HTTP status.
  method=$1 path=$2
  shift 2
  curl --silent --show-error --max-time 30 --output "$work/body" --write-out '%{http_code}' \
    -u "$user:$password" -X "$method" "$@" "$url$path"
}

query_count() {
  code=$(api POST /api/v1/query -H 'Content-Type: application/json' --data \
    "{\"query\":\"select count(*) as c from $stream where msg = '$marker'\",\"startTime\":\"2000-01-01T00:00:00.000Z\",\"endTime\":\"2100-01-01T00:00:00.000Z\"}") ||
    fail 'query request failed'
  [ "$code" = 200 ] || { cat "$work/body" >&2; fail "query returned $code"; }
  cat "$work/body"
}

start_server

# Negative: the API must reject unauthenticated and wrongly authenticated calls.
code=$(curl --silent --output "$work/unauth" --write-out '%{http_code}' --max-time 10 \
  "$url/api/v1/logstream") || fail 'unauthenticated request failed'
[ "$code" = 401 ] || fail "unauthenticated logstream list returned $code, expected 401"
code=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 10 \
  -u "$user:wrong-$password" "$url/api/v1/about") || fail 'bad-password request failed'
# Upstream answers unknown basic credentials with 403, not 401.
[ "$code" = 403 ] || fail "wrong password returned $code, expected 403"
code=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 10 \
  -H "X-P-Stream: $stream" -H 'Content-Type: application/json' \
  --data '[{"msg":"unauthenticated"}]' "$url/api/v1/ingest") || fail 'unauthenticated ingest failed'
[ "$code" = 401 ] || fail "unauthenticated ingest returned $code, expected 401"

# The prebuilt web console is deliberately not embedded.
code=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 10 "$url/") ||
  fail 'root request failed'
[ "$code" = 404 ] || fail "console root returned $code, expected 404"

code=$(api GET /api/v1/about) || fail 'about request failed'
[ "$code" = 200 ] || { cat "$work/body" >&2; fail "about returned $code"; }
grep -qF "\"version\":\"v$expected_version\"" "$work/body" ||
  { cat "$work/body" >&2; fail "about does not report v$expected_version"; }

code=$(api POST /api/v1/ingest -H "X-P-Stream: $stream" -H 'Content-Type: application/json' \
  --data "[{\"msg\":\"$marker\",\"n\":1},{\"msg\":\"$marker\",\"n\":2}]") || fail 'ingest request failed'
[ "$code" = 200 ] || { cat "$work/body" >&2; fail "ingest returned $code"; }

code=$(api GET /api/v1/logstream) || fail 'logstream list failed'
[ "$code" = 200 ] || fail "logstream list returned $code"
grep -qF "\"$stream\"" "$work/body" || { cat "$work/body" >&2; fail "stream $stream not listed"; }

result=$(query_count)
printf '%s' "$result" | grep -q '"c":2' || { printf '%s\n' "$result" >&2; fail 'query did not return 2 events'; }
printf 'query: %s\n' "$result"

docker top "$name" -o pid,uid,comm >"$work/top.txt" || fail 'docker top failed'
awk '$3 == "parseable" { found = 1; if ($2 != 65532) bad = 1 } END { exit !(found && !bad) }' \
  "$work/top.txt" || { cat "$work/top.txt" >&2; fail 'server is not running as 65532'; }

# SIGTERM must stop the server cleanly and flush staged data to the local store.
docker stop --time 60 "$name" >/dev/null
exit_code=$(docker inspect -f '{{.State.ExitCode}}' "$name")
[ "$exit_code" = 0 ] || fail "server exited with $exit_code after SIGTERM"

# Persistence: the stream and its events survive a restart on the same volume.
start_server
code=$(api GET /api/v1/logstream) || fail 'logstream list after restart failed'
grep -qF "\"$stream\"" "$work/body" || { cat "$work/body" >&2; fail 'stream lost after restart'; }
result=$(query_count)
printf '%s' "$result" | grep -q '"c":2' ||
  { printf '%s\n' "$result" >&2; fail 'events lost after restart'; }

printf 'SMOKE PASS image=%s\n' "$image"
