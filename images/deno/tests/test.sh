#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
fixture=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)/fixture.ts

[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/deno"]' ]
[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ]
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /app ]
docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$image" | grep -qx 'DENO_DIR=/deno-dir'

docker run --rm --network none --entrypoint /usr/bin/deno "$image" eval --allow-read=/app,/deno-dir '
  for (const path of ["/app", "/deno-dir"]) {
    const info = await Deno.stat(path);
    if (!info.isDirectory || info.uid !== 65532 || info.gid !== 65532 || info.mode === null || (info.mode & 0o777) !== 0o755) Deno.exit(1);
  }
'
[ "$(docker run --rm --network none -v "$fixture:/fixture.ts:ro" "$image" run /fixture.ts)" = 422 ]
if docker run --rm --network none "$image" eval 'await Deno.readTextFile("/etc/os-release")' >/dev/null 2>&1; then
  exit 1
fi
if docker run --rm --network none "$image" eval 'await fetch("https://example.com")' >/dev/null 2>&1; then
  exit 1
fi

printf '%s\n' 'SMOKE PASS'
