#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*- mailpit=\([0-9.]*\)-r[0-9]*$/\1/p' \
  "$(dirname "$0")/../apko.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
container="verity-mailpit-test-$$"
tmp=$(mktemp -d)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  docker logs "$container" >&2 2>&1 || true
  exit 1
}

test "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532
test "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/mailpit"]'

docker run --name "$container" -d --read-only --tmpfs /tmp:uid=65532,gid=65532 -p 127.0.0.1::8025 -p 127.0.0.1::1025 "$image" >/dev/null
ui=$(docker port "$container" 8025/tcp | awk -F: 'NR == 1 { print $2 }')
smtp=$(docker port "$container" 1025/tcp | awk -F: 'NR == 1 { print $2 }')
test -n "$ui" && test -n "$smtp"

attempts=0
until curl --fail --silent --connect-timeout 1 --max-time 5 \
  "http://127.0.0.1:$ui/api/v1/info" >"$tmp/info.json"; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || fail 'mailpit did not become ready'
  sleep 1
done
version=$(jq -r .Version "$tmp/info.json")
[ "$version" = "$expected_version" ] || fail "unexpected version $version, want $expected_version"

printf 'From: a@example.test\r\nTo: b@example.test\r\nSubject: verity smoke\r\n\r\nhello\r\n' >"$tmp/mail.txt"
curl --fail --silent --show-error "smtp://127.0.0.1:$smtp" \
  --mail-from a@example.test --mail-rcpt b@example.test -T "$tmp/mail.txt" ||
  fail 'SMTP delivery failed'
curl --fail --silent "http://127.0.0.1:$ui/api/v1/messages" >"$tmp/messages.json"
[ "$(jq -r '.messages[0].Subject' "$tmp/messages.json")" = 'verity smoke' ] ||
  fail 'delivered message not listed'

docker stop -t 10 "$container" >/dev/null
[ "$(docker inspect "$container" --format '{{.State.ExitCode}}')" = 0 ] ||
  fail 'mailpit did not exit cleanly on SIGTERM'

if docker run --rm "$image" --ui-auth-file /nonexistent >"$tmp/invalid.log" 2>&1; then
  printf '%s\n' 'invalid config unexpectedly succeeded' >&2
  exit 1
fi
grep -qi 'nonexistent' "$tmp/invalid.log" || {
  cat "$tmp/invalid.log" >&2
  fail 'invalid config error is not readable'
}

printf 'SMOKE PASS image=%s\n' "$image"
