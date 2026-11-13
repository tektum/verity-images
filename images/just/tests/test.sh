#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
config="$(dirname "$0")/../apko.yaml"
version=$(sed -n 's/^    - just=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
work=$(mktemp -d)

trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ -n "$version" ] || fail 'could not read the pinned just version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/just"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

run() {
  dir=$1
  shift
  docker run --rm --network none --read-only --tmpfs /tmp:rw,exec,mode=1777 \
    -v "$dir:/work:ro" "$image" "$@"
}

mkdir -p "$work/project" "$work/empty"
cat >"$work/project/justfile" <<'JUST'
greeting := "hello"

# Print a greeting for NAME
greet name="world": prepare
    @echo "{{greeting}}, {{name}}"

prepare:
    @echo prepared

# Runs through a shebang interpreter
shebang:
    #!/bin/sh
    set -eu
    total=0
    for n in 1 2 3; do total=$((total + n)); done
    echo "total=$total"

upper text:
    @echo "{{uppercase(text)}}"

broken:
    @echo before
    @exit 3
JUST
chmod -R a+rX "$work"

out=$(run "$work/project" --version) || fail 'version failed'
test "$out" = "just $version" || fail "version does not report $version: $out"

out=$(run "$work/project" --summary) || fail 'summary failed'
test "$out" = 'broken greet prepare shebang upper' || fail "unexpected summary: $out"

run "$work/project" --list >"$work/list" || fail 'list failed'
grep -E '^ +greet name="world" +# Print a greeting for NAME$' "$work/list" >/dev/null ||
  fail "list does not document greet: $(cat "$work/list")"

# Dependencies run first; arguments and variables are interpolated through sh.
out=$(run "$work/project" greet ada) || fail 'greet failed'
expected=$(printf 'prepared\nhello, ada')
test "$out" = "$expected" || fail "unexpected greet output: $out"

out=$(run "$work/project" shebang) || fail 'shebang recipe failed'
test "$out" = 'total=6' || fail "unexpected shebang output: $out"

out=$(run "$work/project" upper smoke) || fail 'function recipe failed'
test "$out" = 'SMOKE' || fail "unexpected uppercase output: $out"

out=$(run "$work/project" --dry-run greet 2>&1) || fail 'dry run failed'
printf '%s\n' "$out" | grep -F 'echo "hello, world"' >/dev/null ||
  fail "dry run did not print the command: $out"

# Negative: a failing recipe propagates its exit status with a diagnostic.
rc=0
run "$work/project" broken >"$work/broken" 2>&1 || rc=$?
test "$rc" -eq 3 || fail "failing recipe exited $rc, expected 3"
grep -F 'before' "$work/broken" >/dev/null || fail 'failing recipe did not run its first line'
grep -F 'exit code 3' "$work/broken" >/dev/null || fail 'failing recipe diagnostic is missing'

rc=0
run "$work/project" nosuchrecipe >"$work/unknown" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'unknown recipe unexpectedly succeeded'
grep -F 'nosuchrecipe' "$work/unknown" >/dev/null || fail 'unknown recipe diagnostic is missing'

rc=0
run "$work/empty" >"$work/none" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'missing justfile unexpectedly succeeded'
grep -Fi 'justfile' "$work/none" >/dev/null || fail 'missing justfile diagnostic is missing'

rc=0
run "$work/project" --no-such-flag >"$work/flag" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'unknown flag unexpectedly succeeded'
grep -F "unexpected argument '--no-such-flag'" "$work/flag" >/dev/null ||
  fail "unknown flag diagnostic is missing: $(cat "$work/flag")"

printf 'SMOKE PASS\n'
