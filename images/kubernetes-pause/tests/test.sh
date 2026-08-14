#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-kubernetes-pause-test-$$"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image")
[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65535 ] || {
  printf 'unexpected OCI user\n' >&2
  exit 1
}
version=$(docker run --rm --platform "$platform" "$image" -v)
case "$version" in
  'pause.c v3.10'*) ;;
  *) printf 'unexpected pause version: %s\n' "$version" >&2; exit 1 ;;
esac

docker run --platform "$platform" --name "$container" -d "$image" >/dev/null
sleep 1
[ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ] || {
  printf 'pause process did not remain running\n' >&2
  exit 1
}

docker kill --signal TERM "$container" >/dev/null
[ "$(docker wait "$container")" = 0 ] || {
  printf 'pause did not exit cleanly after SIGTERM\n' >&2
  exit 1
}
docker logs "$container" 2>&1 | grep -q 'Shutting down, got signal: Terminated' || {
  printf 'pause did not report SIGTERM shutdown\n' >&2
  exit 1
}
docker rm "$container" >/dev/null
container=

if docker run --rm --platform "$platform" --entrypoint /bin/sh "$image" >/dev/null 2>&1; then
  printf 'unsupported shell entrypoint unexpectedly succeeded\n' >&2
  exit 1
fi

printf 'SMOKE PASS image=%s\n' "$image"
