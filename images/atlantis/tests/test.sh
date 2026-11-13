#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf '%s\n' 'package version not found' >&2; exit 1; }
container="verity-atlantis-test-$$"
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

inspect() {
  docker image inspect "$image" --format "$1"
}

[ "$(inspect '{{.Config.User}}')" = 100 ] || fail 'unexpected image config: User'
[ "$(inspect '{{json .Config.Entrypoint}}')" = '["/usr/bin/dumb-init","--single-child","--","/usr/local/bin/docker-entrypoint.sh"]' ] ||
  fail 'unexpected image config: Entrypoint'
[ "$(inspect '{{json .Config.Cmd}}')" = '["server"]' ] || fail 'unexpected image config: Cmd'
[ "$(docker run --rm --entrypoint id "$image")" = 'uid=100(atlantis) gid=1000(atlantis) groups=1000(atlantis)' ] ||
  fail 'unexpected runtime identity'
[ "$(docker run --rm --entrypoint sh "$image" -c 'printf %s "$HOME"')" = /home/atlantis ] ||
  fail 'unexpected HOME'

# The upstream entrypoint prefixes atlantis to bare subcommands and flags.
actual=$(docker run --rm "$image" version 2>/dev/null | grep '^atlantis ') ||
  fail 'atlantis version through the entrypoint failed'
case "$actual" in
  "atlantis v$expected_version (commit: "*) ;;
  *) fail "unexpected version output: $actual" ;;
esac
docker run --rm "$image" --help 2>/dev/null | grep -F 'atlantis server' >/dev/null ||
  fail 'flag passthrough through the entrypoint failed'

# Workflow tools the upstream image ships on PATH.
for tool in bash conftest curl dumb-init git git-lfs ssh unzip; do
  docker run --rm --entrypoint sh "$image" -c "command -v $tool" >/dev/null ||
    fail "missing workflow tool: $tool"
done
docker run --rm --entrypoint conftest "$image" --version | grep '^Conftest: ' >/dev/null ||
  fail 'conftest does not run'
docker run --rm --entrypoint git "$image" lfs version | grep -F 'git-lfs/' >/dev/null ||
  fail 'git-lfs does not run'

# Like upstream since v0.49.0, the image ships no Terraform; the server needs a
# default version and would download it on demand (disabled here).
# The server must start with placeholder GitHub credentials, serve its health
# endpoint and UI, persist state under the atlantis home, and reject webhooks
# without a valid signature.
docker run --name "$container" -d --read-only --tmpfs /home/atlantis:uid=100,gid=1000 \
  --tmpfs /tmp -p 127.0.0.1::4141 \
  -e ATLANTIS_GH_USER=verity-smoke \
  -e ATLANTIS_GH_TOKEN=placeholder-not-a-token \
  -e ATLANTIS_GH_WEBHOOK_SECRET=placeholder-webhook-secret \
  -e ATLANTIS_REPO_ALLOWLIST='github.com/example/*' \
  -e ATLANTIS_DEFAULT_TF_VERSION=1.12.2 -e ATLANTIS_TF_DOWNLOAD=false \
  "$image" >/dev/null
port=$(docker port "$container" 4141/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || fail 'no published host port'
attempts=0
until curl --fail --silent --connect-timeout 1 --max-time 5 \
  "http://127.0.0.1:$port/healthz" >"$tmp/health.json"; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || fail 'atlantis did not become ready'
  sleep 1
done
tr -d ' \n' <"$tmp/health.json" | grep -F '"status":"ok"' >/dev/null || {
  cat "$tmp/health.json" >&2
  fail 'unexpected health response'
}
curl --fail --silent "http://127.0.0.1:$port/" >"$tmp/index.html" || fail 'UI index failed'
grep -i 'atlantis' "$tmp/index.html" >/dev/null || fail 'UI index does not render'
docker exec "$container" test -d /home/atlantis/.atlantis ||
  fail 'atlantis did not create its data directory'
status=$(curl --silent -o /dev/null -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' -H 'X-GitHub-Event: ping' \
  --data '{}' "http://127.0.0.1:$port/events")
case "$status" in
  4??) ;;
  *) fail "unsigned webhook was not rejected: HTTP $status" ;;
esac

# dumb-init is PID 1 and forwards signals to the single child.
[ "$(docker exec "$container" cat /proc/1/comm)" = dumb-init ] || fail 'dumb-init is not PID 1'
docker stop -t 30 "$container" >/dev/null
[ "$(docker inspect "$container" --format '{{.State.ExitCode}}')" = 0 ] ||
  fail 'atlantis did not exit cleanly on SIGTERM'
docker rm "$container" >/dev/null

# Negative case: the server refuses to start without a repository allowlist.
# A server that wrongly starts would keep running, so bound the run and keep it
# named for cleanup; exit status 124 is a failure.
status=0
timeout 60 docker run --name "$container" --rm -e ATLANTIS_GH_USER=verity-smoke \
  -e ATLANTIS_GH_TOKEN=placeholder-not-a-token "$image" server \
  >"$tmp/invalid.log" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail 'server without a repository allowlist unexpectedly succeeded'
[ "$status" -ne 124 ] || fail 'server without a repository allowlist did not exit'
grep -F 'repo-allowlist' "$tmp/invalid.log" >/dev/null || {
  cat "$tmp/invalid.log" >&2
  fail 'missing allowlist error is not readable'
}

# Negative case: without Terraform on PATH or a default version, the server
# refuses to start and names the missing setting.
status=0
timeout 60 docker run --name "$container" --rm -e ATLANTIS_GH_USER=verity-smoke \
  -e ATLANTIS_GH_TOKEN=placeholder-not-a-token \
  -e ATLANTIS_REPO_ALLOWLIST='github.com/example/*' "$image" server \
  >"$tmp/notf.log" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail 'server without a Terraform version unexpectedly succeeded'
[ "$status" -ne 124 ] || fail 'server without a Terraform version did not exit'
grep -F -- '--default-tf-version' "$tmp/notf.log" >/dev/null || {
  cat "$tmp/notf.log" >&2
  fail 'missing Terraform version error is not readable'
}

printf 'SMOKE PASS image=%s\n' "$image"
