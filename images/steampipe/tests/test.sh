#!/bin/sh
# Steampipe downloads its embedded PostgreSQL and FDW from ghcr.io the first
# time a command needs the database (query, service start, plugin list). That
# download is an upstream runtime dependency, not part of this image, so every
# container here runs with --network none and the test covers the offline
# contract: image config, version, help, service status, the install
# directory volume, the uname and shared libraries the downloaded binaries
# need, root refusal, and a clean failure when the database cannot be fetched.
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -n "$expected_version" ] || fail 'package version not found in melange.yaml'

run() {
  docker run --rm --network none "$@"
}

inspect() {
  docker image inspect "$image" --format "$1"
}

[ "$(inspect '{{.Config.User}}')" = 65532 ] || fail 'image user is not 65532'
[ "$(inspect '{{json .Config.Entrypoint}}')" = '["/usr/bin/steampipe"]' ] ||
  fail 'unexpected entrypoint'
[ "$(inspect '{{.Config.WorkingDir}}')" = /workspace ] || fail 'unexpected working directory'
env=$(inspect '{{range .Config.Env}}{{println .}}{{end}}')
for want in HOME=/home/nonroot USER=nonroot \
  STEAMPIPE_INSTALL_DIR=/home/nonroot/.steampipe \
  STEAMPIPE_UPDATE_CHECK=false STEAMPIPE_TELEMETRY=none; do
  printf '%s\n' "$env" | grep -Fx "$want" >/dev/null || fail "missing env $want"
done

# The FDW download is selected from `uname -m`, and the downloaded PostgreSQL
# and FDW binaries are glibc executables that also need libz.
case "$(inspect '{{.Architecture}}')" in
  amd64) machine=x86_64 loader=/lib64/ld-linux-x86-64.so.2 ;;
  arm64) machine=aarch64 loader=/lib/ld-linux-aarch64.so.1 ;;
  *) fail "unsupported image architecture $(inspect '{{.Architecture}}')" ;;
esac
out=$(run --entrypoint uname "$image" -m) || fail 'uname is missing from the image'
[ "$out" = "$machine" ] || fail "uname -m reported $out, expected $machine"
for lib in "$loader" /usr/lib/libc.so.6 /usr/lib/libm.so.6 /usr/lib/libz.so.1; do
  run --entrypoint test "$image" -e "$lib" ||
    fail "runtime library $lib is missing"
done

# Capture stderr too: steampipe execs uname on every start and reports an
# error when the image lacks it.
out=$(run "$image" --version 2>&1) || fail '--version exited non-zero'
[ "$out" = "Steampipe v$expected_version" ] ||
  fail "unexpected version output: $out"

out=$(run "$image" --help) || fail '--help exited non-zero'
for cmd in plugin query service; do
  printf '%s\n' "$out" | grep -E "^  ${cmd}[[:space:]]" >/dev/null ||
    fail "--help does not list the $cmd command"
done
printf '%s\n' "$out" | grep -F '(default "/home/nonroot/.steampipe")' >/dev/null ||
  fail '--help does not report the image install directory'

# service status needs no database. It initialises the default install
# directory as the image user.
out=$(run "$image" service status 2>&1) || fail 'service status exited non-zero'
[ "$out" = 'Steampipe service is not installed.' ] ||
  fail "unexpected service status: $out"

# The install directory works as a volume owned by an arbitrary non-root UID
# that has no /etc/passwd entry.
chmod 0777 "$tmp"
user=$(id -u):$(id -g)
[ "$(id -u)" != 0 ] || user=12345:12345
out=$(run --user "$user" -e HOME=/data -e STEAMPIPE_INSTALL_DIR=/data/.steampipe \
  -v "$tmp:/data" "$image" service status 2>&1) ||
  fail "service status on a volume exited non-zero: $out"
[ "$out" = 'Steampipe service is not installed.' ] ||
  fail "unexpected service status on a volume: $out"
[ -s "$tmp/.steampipe/config/default.spc.sample" ] ||
  fail 'install directory volume was not initialised'
[ "$(stat -c %u:%g "$tmp/.steampipe/config")" = "$user" ] ||
  fail 'install directory is not owned by the run user'

# Unknown commands fail.
if run "$image" no-such-command >/dev/null 2>&1; then
  fail 'unknown command unexpectedly succeeded'
fi

# Steampipe refuses to run as root; the image must not weaken that check.
if out=$(run --user 0 "$image" --version 2>&1); then
  fail 'steampipe unexpectedly ran as root'
fi
printf '%s\n' "$out" | grep -F 'cannot be run as the "root" user' >/dev/null ||
  fail "unexpected root refusal message: $out"

# Without network the embedded database cannot be installed. The query must
# fail with a non-zero status and not hang or report success.
status=0
out=$(timeout 300 docker run --rm --network none "$image" query 'select 1' 2>&1) ||
  status=$?
[ "$status" -ne 0 ] || fail "offline query unexpectedly succeeded: $out"
[ "$status" -ne 124 ] || fail 'offline query did not terminate within 300s'

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$expected_version"
