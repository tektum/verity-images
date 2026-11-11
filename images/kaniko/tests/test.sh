#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
workdir=$(mktemp -d)
containers=

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  for container in $containers; do
    docker rm -f "$container" >/dev/null 2>&1 || true
  done
  rm -rf "$workdir"
}
trap cleanup EXIT INT TERM

# kaniko unpacks layers over its own root filesystem, so it runs as root, like upstream.
case $(docker image inspect -f '{{.Config.User}}' "$image") in
  ''|0|root) ;;
  *) fail 'unexpected OCI user' ;;
esac
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/kaniko/executor"]' ] \
  || fail 'unexpected OCI entrypoint'
case $(docker image inspect -f '{{json .Config.Cmd}}' "$image") in
  null|'[]') ;;
  *) fail 'unexpected OCI command' ;;
esac

version_output=$(docker run --rm --network none "$image" version 2>&1) || fail 'executor version failed'
printf '%s\n' "$version_output" | grep -F "v$expected_version" >/dev/null \
  || fail "unexpected version output: $version_output"

# A one-stage FROM scratch build: copy the build context into a container without bind mounts,
# build with --no-push --tar-path and read the tarball back.
mkdir "$workdir/ctx"
printf 'FROM scratch\nCOPY hello.txt /hello.txt\n' >"$workdir/ctx/Dockerfile"
printf 'hello kaniko\n' >"$workdir/ctx/hello.txt"

container="verity-kaniko-test-$$-ok"
containers="$containers $container"
docker create --name "$container" --network none "$image" \
  --context dir:///workspace --dockerfile /workspace/Dockerfile \
  --no-push --tar-path /kaniko/out.tar --destination smoke:latest >/dev/null
docker cp "$workdir/ctx/." "$container:/workspace"
docker start -a "$container" >"$workdir/build.log" 2>&1 \
  || { cat "$workdir/build.log" >&2; fail 'kaniko build failed'; }
docker cp "$container:/kaniko/out.tar" "$workdir/out.tar" || fail 'kaniko did not write the tarball'

mkdir "$workdir/out"
tar -xf "$workdir/out.tar" -C "$workdir/out"
[ -f "$workdir/out/manifest.json" ] || fail 'tarball has no manifest.json'
found=
for layer in "$workdir"/out/*.tar.gz "$workdir"/out/*.tar; do
  [ -f "$layer" ] || continue
  if tar -tzf "$layer" 2>/dev/null | grep -Fx 'hello.txt' >/dev/null \
    || tar -tf "$layer" 2>/dev/null | grep -Fx 'hello.txt' >/dev/null; then
    found=1
  fi
done
[ -n "$found" ] || fail 'built image does not contain the copied file'

# Negative: a missing Dockerfile must fail with a readable error.
container="verity-kaniko-test-$$-bad"
containers="$containers $container"
docker create --name "$container" --network none "$image" \
  --context dir:///workspace --dockerfile /workspace/Missing \
  --no-push --tar-path /kaniko/out.tar --destination smoke:latest >/dev/null
docker cp "$workdir/ctx/." "$container:/workspace"
if docker start -a "$container" >"$workdir/bad.log" 2>&1; then
  fail 'build with a missing Dockerfile unexpectedly succeeded'
fi
grep -iE 'dockerfile|no such file' "$workdir/bad.log" >/dev/null \
  || { cat "$workdir/bad.log" >&2; fail 'missing Dockerfile was not reported'; }

printf 'SMOKE PASS image=%s\n' "$image"
