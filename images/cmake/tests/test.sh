#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^\"]*\)"$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
work=$(mktemp -d)

cleanup() {
  docker run --rm -v "$work:/work" "$image" -E remove_directory /work/build >/dev/null 2>&1 || true
  docker run --rm -v "$work:/work" "$image" -E remove_directory /work/invalid-build >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$work/project" "$work/build" "$work/invalid" "$work/invalid-build"
cat >"$work/project/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 4.1)
project(verity NONE)
file(WRITE "${CMAKE_BINARY_DIR}/configured.txt" "configured\n")
add_custom_target(smoke ALL
  COMMAND "${CMAKE_COMMAND}" -E touch "${CMAKE_BINARY_DIR}/built.txt")
EOF
cat >"$work/invalid/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 4.1)
project(verity NONE)
verity_unknown_command()
EOF
chmod -R a+rX "$work"
chmod a+rwx "$work/build" "$work/invalid-build"

version=$(docker run --rm "$image" --version)
printf '%s\n' "$version" | grep -Fxq "cmake version $expected_version"
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/cmake"]'
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532

docker run --rm --read-only -v "$work:/work" "$image" \
  -G Ninja -S /work/project -B /work/build
grep -Fxq configured "$work/build/configured.txt"
test -f "$work/build/CMakeCache.txt"
docker run --rm --read-only -v "$work:/work" "$image" --build /work/build
test -f "$work/build/built.txt"

if docker run --rm --read-only -v "$work:/work" "$image" \
  -G Ninja -S /work/invalid -B /work/invalid-build >/dev/null 2>&1; then
  printf '%s\n' 'invalid CMake project unexpectedly configured' >&2
  exit 1
fi

printf 'SMOKE PASS version=%s\n' "$(printf '%s\n' "$version" | sed -n '1p')"
