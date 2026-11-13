#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
lock="$here/../apko.lock.json"
work=$(mktemp -d)
volume=uv-smoke-$$
container=
cleanup() {
  [ -z "$container" ] || docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

run() {
  docker run --rm --network none "$@"
}

case "$(docker image inspect -f '{{.Architecture}}' "$image")" in
  amd64) apk_arch=x86_64 ;;
  arm64) apk_arch=aarch64 ;;
  *) fail 'unsupported image architecture' ;;
esac
apk_version=$(jq -r --arg arch "$apk_arch" \
  '.contents.packages[] | select(.name == "uv" and .architecture == $arch) | .version' "$lock")
version=${apk_version%-r*}
[ -n "$version" ] || fail "uv package for $apk_arch is missing from $lock"

# OCI contract: uv entrypoint, upstream /io work directory, nonroot user.
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/uv"]' ] || fail 'wrong entrypoint'
[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'wrong user'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /io ] || fail 'wrong work directory'
env_list=$(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$image")
for expected in HOME=/home/nonroot UV_CACHE_DIR=/home/nonroot/.cache/uv UV_PYTHON_DOWNLOADS=manual UV_LINK_MODE=copy; do
  printf '%s\n' "$env_list" | grep -qx "$expected" || fail "missing environment $expected"
done

# Versions: uv and uvx report the locked Wolfi package version.
uv_version=$(run "$image" --version) || fail 'uv --version failed'
case "$uv_version" in
  "uv $version "*) ;;
  *) fail "uv --version: got '$uv_version', want uv $version" ;;
esac
uvx_version=$(run --entrypoint /usr/bin/uvx "$image" --version) || fail 'uvx --version failed'
case "$uvx_version" in
  "uvx $version "*) ;;
  *) fail "uvx --version: got '$uvx_version', want uvx $version" ;;
esac

# Filesystem: upstream COPY --from paths /uv and /uvx are the packaged binaries,
# no Python interpreter ships, and /io plus the cache directory belong to 65532.
container=$(docker create "$image")
docker export "$container" >"$work/rootfs.tar" || fail 'image export failed'
docker rm "$container" >/dev/null
container=
tar -tv --numeric-owner -f "$work/rootfs.tar" >"$work/listing" || fail 'image listing failed'
for dir in io/ home/nonroot/ home/nonroot/.cache/uv/; do
  grep -Eq "^d[^ ]* 65532/65532 .* $dir\$" "$work/listing" || fail "$dir is not owned by 65532"
done
if grep -Eq ' usr/bin/python[0-9.]*$' "$work/listing"; then
  fail 'image unexpectedly ships a Python interpreter'
fi
mkdir "$work/rootfs"
tar -xf "$work/rootfs.tar" -C "$work/rootfs" uv uvx usr/bin/uv usr/bin/uvx || fail 'missing uv binaries'
rm -f "$work/rootfs.tar"
cmp -s "$work/rootfs/uv" "$work/rootfs/usr/bin/uv" || fail '/uv differs from /usr/bin/uv'
cmp -s "$work/rootfs/uvx" "$work/rootfs/usr/bin/uvx" || fail '/uvx differs from /usr/bin/uvx'
rm -rf "$work/rootfs"
[ "$(run --entrypoint /uv "$image" --version)" = "$uv_version" ] || fail '/uv is not runnable'

# The default cache directory is writable: prune takes a lock file there, and
# the same command fails on a read-only root filesystem.
run "$image" cache prune >/dev/null 2>"$work/prune.err" || {
  cat "$work/prune.err" >&2
  fail 'uv cache prune failed in the default cache directory'
}
if run --read-only "$image" cache prune >/dev/null 2>"$work/prune-ro.err"; then
  fail 'cache prune succeeded on a read-only root filesystem'
fi
grep -q 'Read-only file system' "$work/prune-ro.err" || fail 'read-only cache prune diagnostic missing'

# Offline project creation and version bump with the network disabled. A fresh
# named volume on /io inherits the image directory ownership (65532).
docker volume create "$volume" >/dev/null
run -v "$volume:/io" "$image" \
  init --offline --lib --name demo --python 3.12 --no-pin-python --vcs none --no-workspace demo \
  >"$work/init.out" 2>&1 || {
  cat "$work/init.out" >&2
  fail 'uv init failed offline'
}
bumped=$(run -v "$volume:/io" -w /io/demo "$image" version --bump minor --frozen --short) ||
  fail 'uv version --bump failed offline'
[ "$bumped" = 0.2.0 ] || fail "uv version --bump: got '$bumped', want 0.2.0"
container=$(docker create -v "$volume:/io" "$image")
docker cp "$container:/io/demo/pyproject.toml" "$work/pyproject.toml" || fail 'uv init wrote no pyproject.toml'
docker cp "$container:/io/demo/src/demo/__init__.py" "$work/__init__.py" || fail 'uv init wrote no package module'
docker rm "$container" >/dev/null
container=
pyproject="$work/pyproject.toml"
grep -qx 'name = "demo"' "$pyproject" || fail 'project name not written'
grep -qx 'version = "0.2.0"' "$pyproject" || fail 'bumped version not written'
grep -qx 'requires-python = ">=3.12"' "$pyproject" || fail 'requires-python not written'
grep -qx 'build-backend = "uv_build"' "$pyproject" || fail 'uv_build backend not selected'
grep -Fq "\"uv_build>=$version," "$pyproject" || fail "uv_build requirement does not start at $version"

# Negative: an unknown subcommand exits non-zero with its diagnostic.
if run "$image" frobnicate >"$work/unknown.out" 2>"$work/unknown.err"; then
  fail 'unknown subcommand exited zero'
fi
grep -q "unrecognized subcommand 'frobnicate'" "$work/unknown.err" || fail 'unknown subcommand diagnostic missing'

# Negative: no interpreter ships and downloads are manual, so a venv needs an
# explicit `uv python install` instead of an implicit network fetch.
if run --tmpfs /io:uid=65532,gid=65532 "$image" venv /io/venv >/dev/null 2>"$work/venv.err"; then
  fail 'uv venv succeeded without an interpreter'
fi
grep -q 'No interpreter found' "$work/venv.err" || fail 'missing interpreter diagnostic'
grep -q "Python downloads are set to 'manual'" "$work/venv.err" || fail 'manual download policy diagnostic missing'

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$version"
