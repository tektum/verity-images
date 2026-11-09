#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
fixture=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
server=bun-smoke-$$
trap 'docker rm -f "$server" >/dev/null 2>&1 || true' EXIT INT TERM

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/bun"]' ] || fail 'wrong entrypoint'
[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'wrong user'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /app ] || fail 'wrong work directory'
docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$image" | grep -qx 'HOME=/home/nonroot' || fail 'wrong HOME'

version=$(docker run --rm --network none "$image" --version)
case "$version" in
  1.*) ;;
  *) fail "unexpected bun version: $version" ;;
esac
[ "$(docker run --rm --network none --entrypoint /usr/bin/bunx "$image" --version)" = "$version" ] || fail 'bunx is not bun'

docker run -d --name "$server" --label verity.smoke=bun --network none \
  -v "$fixture:/fixture:ro" "$image" /fixture/fixture.ts serve >/dev/null
expected="200 bun $version 42 404"
actual=
i=0
while [ "$i" -lt 30 ]; do
  actual=$(docker exec "$server" /usr/bin/bun /fixture/fixture.ts get 2>/dev/null) && break
  i=$((i + 1))
  sleep 1
done
[ "$actual" = "$expected" ] || { docker logs "$server" >&2; fail "Bun.serve response: got '$actual', want '$expected'"; }

installed=$(docker run --rm --network none --tmpfs /app:uid=65532,gid=65532 \
  -v "$fixture:/fixture:ro" "$image" /fixture/fixture.ts install) || fail 'bun install from local fixture failed'
[ "$installed" = 'hello verity' ] || fail "installed package output: got '$installed'"

if docker run --rm --network none "$image" -e 'throw new Error("expected failure")' >/dev/null 2>&1; then
  fail 'throwing script exited zero'
fi
if docker run --rm --network none "$image" /fixture/missing.ts >/dev/null 2>&1; then
  fail 'missing script exited zero'
fi

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$version"
