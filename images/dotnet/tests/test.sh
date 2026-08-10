#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/dotnet"]' ] || fail 'unexpected OCI entrypoint'
[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /app ] || fail 'unexpected OCI working directory'

runtimes=$(docker run --rm --network none "$image" --list-runtimes 2>&1)
printf '%s\n' "$runtimes" | grep -F 'Microsoft.NETCore.App 8.' >/dev/null || fail '.NET 8 runtime not installed'
sdks=$(docker run --rm --network none "$image" --list-sdks 2>&1) || fail 'dotnet SDK listing failed'
[ -z "$sdks" ] || fail 'SDK unexpectedly installed'
docker run --rm --network none "$image" --info >/dev/null || fail 'dotnet runtime info failed'

printf 'SMOKE PASS image=%s\n' "$image"
