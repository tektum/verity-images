#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
fixture=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)/fixture.ts
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/deno"]' ] || { printf 'wrong entrypoint\n' >&2; exit 1; }
[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || { printf 'wrong user\n' >&2; exit 1; }
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /app ] || { printf 'wrong work directory\n' >&2; exit 1; }
docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$image" | grep -qx 'DENO_DIR=/deno-dir' || { printf 'wrong DENO_DIR\n' >&2; exit 1; }

docker run --rm --network none -v "$fixture:/fixture.ts:ro" "$image" run --allow-read=/app,/deno-dir /fixture.ts directories || { printf 'wrong directory metadata\n' >&2; exit 1; }
docker run --rm --network none -v "$fixture:/fixture.ts:ro" "$image" run --allow-sys=uid,gid /fixture.ts identity || { printf 'wrong runtime identity\n' >&2; exit 1; }
[ "$(docker run --rm --network none -v "$fixture:/fixture.ts:ro" "$image" run --no-prompt /fixture.ts)" = 422 ] || { printf 'fixture failed\n' >&2; exit 1; }

for mode in read net; do
  if docker run --rm --network none -v "$fixture:/fixture.ts:ro" "$image" run --no-prompt "/fixture.ts" "$mode" >"$work/$mode.out" 2>"$work/$mode.err"; then
    printf '%s permission was granted\n' "$mode" >&2
    exit 1
  fi
  grep -q 'NotCapable' "$work/$mode.err" || { printf '%s failed for the wrong reason\n' "$mode" >&2; cat "$work/$mode.err" >&2; exit 1; }
done

printf '%s\n' 'SMOKE PASS'
