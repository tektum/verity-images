#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
fixture=$here/fixture
recipe=$here/../melange.yaml

# The expected release and source commit come from the recipe, so a version bump
# needs no edit here.
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' "$recipe" | head -n 1)
source_commit=$(sed -n 's/^[[:space:]]*source-commit: \([0-9a-f]\{40\}\).*$/\1/p' "$recipe" | head -n 1)
[ -n "$expected_version" ] || { printf 'package version not found in %s\n' "$recipe" >&2; exit 1; }
[ -n "$source_commit" ] || { printf 'source commit not found in %s\n' "$recipe" >&2; exit 1; }
short_commit=$(printf '%.12s' "$source_commit")

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

# Every run is offline, as the image's non-root user, on a read-only root
# filesystem. /tmp is the only writable path and must allow exec for venv scripts.
run() {
  docker run --rm --network none --read-only \
    --tmpfs /tmp:exec,uid=65532,gid=65532,mode=1777 \
    -e PIP_NO_CACHE_DIR=1 "$@"
}

[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/pypy3"]' ] || fail 'unexpected entrypoint'
[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected user'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /app ] || fail 'unexpected work directory'
env_lines=$(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$image")
printf '%s\n' "$env_lines" | grep -qx 'HOME=/home/nonroot' || fail 'unexpected HOME'
printf '%s\n' "$env_lines" | grep -qx 'PATH=/opt/pypy/bin:/usr/bin:/bin' || fail 'unexpected PATH'

# The banner names the Python level, the release and the exact source commit.
banner=$(run "$image" --version) || fail 'pypy3 --version failed'
first_line=$(printf '%s\n' "$banner" | sed -n 1p)
second_line=$(printf '%s\n' "$banner" | sed -n 2p)
case "$first_line" in
  "Python 3.11."*" ($short_commit, "*) ;;
  *) fail "unexpected interpreter banner: $first_line (want Python 3.11 at $short_commit)" ;;
esac
case "$second_line" in
  "[PyPy $expected_version with GCC "*"]") ;;
  *) fail "unexpected PyPy banner: $second_line (want PyPy $expected_version)" ;;
esac

# The interpreter and its pip are reachable through the documented names.
for command in pypy pypy3 python python3 python3.11; do
  [ "$(run --entrypoint "/opt/pypy/bin/$command" "$image" --version)" = "$banner" ] ||
    fail "/opt/pypy/bin/$command is not the interpreter"
done
[ "$(run --entrypoint /usr/bin/pypy3 "$image" --version)" = "$banner" ] || fail '/usr/bin/pypy3 is not the interpreter'

implementation=$(run "$image" -c 'import sys; print(sys.implementation.name)') || fail 'implementation query failed'
[ "$implementation" = pypy ] || fail "sys.implementation.name is $implementation, want pypy"

probe=$(run -v "$fixture:/fixture:ro" "$image" /fixture/stdlib_probe.py "$expected_version") ||
  { printf '%s\n' "$probe" >&2; fail 'stdlib probe failed'; }
[ "$(printf '%s\n' "$probe" | tail -n 1)" = 'PROBE PASS' ] || fail 'stdlib probe did not finish'

pip_probe=$(run -v "$fixture:/fixture:ro" "$image" /fixture/pip_probe.py) ||
  { printf '%s\n' "$pip_probe" >&2; fail 'pip probe failed'; }
[ "$(printf '%s\n' "$pip_probe" | tail -n 1)" = 'PIP PASS' ] || fail 'pip probe did not finish'

pip_version=$(run --entrypoint /opt/pypy/bin/pip "$image" --version) || fail 'pip entry point failed'
case "$pip_version" in
  "pip "*" from /opt/pypy/lib/pypy3.11/site-packages/pip (python 3.11)") ;;
  *) fail "unexpected pip entry point output: $pip_version" ;;
esac

# The interpreter's tree must be closed to the image user on its own merits, not
# only because the probes above run on a read-only root. Without --read-only the
# write must be refused for permissions (EACCES), not for a read-only mount.
status=0
docker run --rm --network none "$image" -c '
import errno, sys
try:
    open("/opt/pypy/lib/pypy3.11/site-packages/write-probe", "w").close()
except OSError as error:
    sys.exit(0 if error.errno == errno.EACCES else 2)
sys.exit(1)
' >/dev/null 2>&1 || status=$?
case "$status" in
  0) ;;
  1) fail 'the image user can write to the interpreter site-packages' ;;
  *) fail "writing to the interpreter site-packages failed for the wrong reason (status $status)" ;;
esac

# Failures must be reported, not swallowed.
status=0
run "$image" -c 'import sys; sys.exit(7)' >/dev/null 2>&1 || status=$?
[ "$status" -eq 7 ] || fail "exit status was $status, want 7"
if run "$image" -c 'import module_that_does_not_exist' >/dev/null 2>&1; then
  fail 'importing a missing module succeeded'
fi
if run "$image" -c 'this is not python' >/dev/null 2>&1; then
  fail 'a syntax error was accepted'
fi
if run "$image" /fixture/missing.py >/dev/null 2>&1; then
  fail 'a missing script exited zero'
fi
if run "$image" --no-such-flag >/dev/null 2>&1; then
  fail 'an unknown interpreter flag was accepted'
fi

printf 'SMOKE PASS image=%s pypy=%s\n' "$image" "$expected_version"
