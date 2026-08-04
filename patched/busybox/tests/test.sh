#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
case "$image" in
  *-amd64) arch=amd64; base=${image%-amd64} ;;
  *-arm64) arch=arm64; base=${image%-arm64} ;;
  *) exit 1 ;;
esac
upstream="${base}-upstream-${arch}"

test "$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image")" = "linux/$arch"
test "$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$upstream")" = "linux/$arch"
test "$(docker image inspect --format '{{.Id}}' "$image")" = "$(docker image inspect --format '{{.Id}}' "$upstream")"
test "$(docker image inspect --format '{{json .Config}}' "$image")" = "$(docker image inspect --format '{{json .Config}}' "$upstream")"
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["sh"]'
docker run --rm "$image" sh -c '
  set -e
  busybox | grep -q "v1.38.0"
  command -v sh ash cat cp grep sed awk tar uname printf >/dev/null
  printf "%s\\n" "alpha beta" | grep beta | sed "s/beta/gamma/" | awk "{print \$2}" | grep -qx gamma
'
