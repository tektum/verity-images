#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
lock="$here/../apko.lock.json"
ctr=pnpm-smoke-$$
trap 'docker rm -f "$ctr" >/dev/null 2>&1 || true' EXIT INT TERM

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

# The committed lock is the version authority for this pure APKO image.
expected=$(jq -r '[.contents.packages[] | select(.name == "pnpm-12") | .version | sub("-r[0-9]+$"; "")]
  | unique | if length == 1 then .[0] else error("pnpm-12 versions differ across architectures") end' "$lock") ||
  fail 'cannot read pnpm-12 version from apko.lock.json'
node_major=$(jq -r '[.contents.packages[] | select(.name | test("^nodejs-[0-9]+$")) | .name | ltrimstr("nodejs-")]
  | unique | if length == 1 then .[0] else error("expected one nodejs package") end' "$lock") ||
  fail 'cannot read nodejs package from apko.lock.json'

[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/pnpm"]' ] || fail 'wrong entrypoint'
[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'wrong user'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /app ] || fail 'wrong work directory'
docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$image" | grep -qx 'HOME=/home/nonroot' ||
  fail 'wrong HOME'

version=$(docker run --rm --network none "$image" --version) || fail 'pnpm --version failed'
[ "$version" = "$expected" ] || fail "pnpm --version: got '$version', want '$expected'"

# One long-lived container with a writable /app; every step below runs as the
# image's non-root user without network access.
docker run -d --name "$ctr" --network none --tmpfs /app:uid=65532,gid=65532 \
  -v "$here/project:/fixture:ro" --entrypoint /bin/sleep "$image" 300 >/dev/null ||
  fail 'cannot start smoke container'
docker exec "$ctr" /bin/sh -c 'cp -R /fixture/. /app/' || fail 'cannot copy fixture project'
[ "$(docker exec "$ctr" id -u)" = 65532 ] || fail 'exec does not run as 65532'

docker exec "$ctr" pnpm install >/dev/null 2>&1 || {
  docker exec "$ctr" pnpm install >&2 || true
  fail 'pnpm install of a local file dependency failed'
}
docker exec "$ctr" test -f /app/pnpm-lock.yaml || fail 'pnpm install wrote no pnpm-lock.yaml'
docker exec "$ctr" test -L /app/node_modules/greeting || fail 'greeting is not linked into node_modules'

greeted=$(docker exec "$ctr" pnpm run --silent greet) || fail 'pnpm run greet failed'
[ "$greeted" = "hello verity node=$node_major" ] ||
  fail "pnpm run greet: got '$greeted', want 'hello verity node=$node_major'"

# A frozen, offline reinstall must reproduce node_modules from the lockfile alone.
docker exec "$ctr" rm -rf /app/node_modules || fail 'cannot remove node_modules'
docker exec "$ctr" pnpm install --frozen-lockfile --offline >/dev/null 2>&1 || fail 'frozen offline reinstall failed'
[ "$(docker exec "$ctr" pnpm run --silent greet)" = "hello verity node=$node_major" ] ||
  fail 'greet output changed after frozen offline reinstall'

# Negative cases.
if out=$(docker exec "$ctr" pnpm frobnicate 2>&1); then
  fail 'unknown pnpm command exited zero'
fi
printf '%s\n' "$out" | grep -q 'frobnicate' || fail "unknown command error does not name the command: $out"
if out=$(docker exec "$ctr" pnpm run no-such-script 2>&1); then
  fail 'missing script exited zero'
fi
printf '%s\n' "$out" | grep -q 'no-such-script' || fail "missing script error does not name the script: $out"
status=0
docker exec "$ctr" pnpm run --silent fail >/dev/null 2>&1 || status=$?
[ "$status" -eq 3 ] || fail "failing script exit status: got $status, want 3"

printf 'SMOKE PASS image=%s version=%s node=%s\n' "$image" "$version" "$node_major"
