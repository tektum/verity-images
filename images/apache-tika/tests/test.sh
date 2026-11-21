#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE [FLAVOR]}
flavor=${2:-plain}
here=$(cd "$(dirname "$0")" && pwd)
fixture=$here/fixture.pdf
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' "$here/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
# The text, title, and type the committed fixture PDF carries.
expected_text='Verity Tika smoke fixture 7f3a'
expected_title='Verity smoke fixture'
name=verity-apache-tika-$$
work=$(mktemp -d)

cleanup() {
  docker rm -f "$name" "$name-invalid" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  docker logs "$name" 2>&1 | tail -n 40 >&2 || true
  exit 1
}

case $flavor in plain) ;; *) fail "unsupported flavor $flavor" ;; esac
[ -s "$fixture" ] || fail "missing fixture $fixture"

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 35002 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/tika-server"]' ] ||
  fail 'unexpected entrypoint'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /home/tika ] ||
  fail 'unexpected working directory'
[ "$(docker run --rm --entrypoint id "$image" -u)" = 35002 ] || fail 'runtime user is not 35002'
[ "$(docker run --rm --entrypoint id "$image" -g)" = 35002 ] || fail 'runtime group is not 35002'
docker run --rm --entrypoint java "$image" -version >"$work/java.log" 2>&1 || fail 'Java failed'
grep -q 'version "17' "$work/java.log" || fail 'Java 17 is missing'

# Negative: a missing configuration file must stop the server with a readable error.
if docker run --name "$name-invalid" "$image" -c /missing/tika-config.xml >"$work/invalid.log" 2>&1; then
  fail 'missing configuration unexpectedly started the server'
fi
grep -q 'NoSuchFileException: /missing/tika-config.xml' "$work/invalid.log" ||
  { cat "$work/invalid.log" >&2; fail 'missing configuration did not fail clearly'; }
[ "$(docker inspect -f '{{.State.ExitCode}}' "$name-invalid")" != 0 ] || fail 'invalid config exited 0'

docker run -d --name "$name" -p 127.0.0.1::9998 "$image" >/dev/null
port=$(docker port "$name" 9998/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || fail 'port 9998 is not published'
url=http://127.0.0.1:$port

i=0
until greeting=$(curl --fail --silent --connect-timeout 1 --max-time 5 "$url/tika"); do
  i=$((i + 1))
  [ "$i" -lt 120 ] || fail 'Tika server did not become ready'
  [ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ] || fail 'Tika server exited during startup'
  sleep 1
done
[ "$greeting" = "This is Tika Server (Apache Tika $expected_version). Please PUT" ] ||
  fail "unexpected greeting: $greeting"

# Extract the text of the committed PDF fixture.
curl --fail --silent --show-error --max-time 60 -X PUT -H 'Accept: text/plain' \
  -H 'Content-Type: application/pdf' --data-binary "@$fixture" "$url/tika" >"$work/text.txt" ||
  fail 'text extraction request failed'
grep -qx "$expected_text" "$work/text.txt" ||
  { cat "$work/text.txt" >&2; fail 'extracted text does not match the fixture'; }
printf 'extracted: %s\n' "$(grep -x "$expected_text" "$work/text.txt")"

# Detection uses magic bytes only: no Content-Type or file name is sent.
detected=$(curl --fail --silent --show-error --max-time 60 -X PUT -H 'Content-Type:' \
  --data-binary "@$fixture" "$url/detect/stream") || fail 'detect request failed'
[ "$detected" = application/pdf ] || fail "unexpected detected type: $detected"

curl --fail --silent --show-error --max-time 60 -X PUT -H 'Accept: application/json' \
  -H 'Content-Type:' --data-binary "@$fixture" "$url/meta" >"$work/meta.json" ||
  fail 'metadata request failed'
grep -q '"Content-Type":"application/pdf"' "$work/meta.json" ||
  { cat "$work/meta.json" >&2; fail 'metadata does not report application/pdf'; }
grep -q "\"dc:title\":\"$expected_title\"" "$work/meta.json" ||
  { cat "$work/meta.json" >&2; fail 'metadata does not report the fixture title'; }

[ "$(docker exec "$name" id -u)" = 35002 ] || fail 'server is not running as 35002'

# SIGTERM must stop the server cleanly (exit 0, or 143 when the JVM exits on the signal).
docker stop --time 30 "$name" >/dev/null
exit_code=$(docker inspect -f '{{.State.ExitCode}}' "$name")
case "$exit_code" in
  0 | 143) ;;
  *) fail "server exited with $exit_code after SIGTERM" ;;
esac

printf 'SMOKE PASS image=%s\n' "$image"
