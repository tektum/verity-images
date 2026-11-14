#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d)

cleanup() {
  # The container user owns files it created in the bind mount; remove them as that user.
  if [ -d "$work/project" ]; then
    docker run --rm --network none --entrypoint /bin/rm -v "$work/project:/work" "$image" \
      -rf /work/out /work/.task >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
[ -n "$version" ] || fail 'could not read the recipe version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/task"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

run() {
  docker run --rm --network none --read-only --cap-drop=ALL \
    --tmpfs /tmp:rw,mode=1777 -v "$work/project:/work" "$image" "$@"
}

mkdir -p "$work/project"
chmod 777 "$work/project"

run --version >"$work/version" 2>&1 || fail "version failed: $(cat "$work/version")"
grep -Ex "(Task version: )?v?$version" "$work/version" >/dev/null ||
  fail "version does not report $version: $(cat "$work/version")"

rc=0
run --definitely-invalid >"$work/invalid" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"

# Negative: no Taskfile in the working directory is an error.
rc=0
run >"$work/missing" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'run without a Taskfile unexpectedly succeeded'
grep -Ei 'no Taskfile found' "$work/missing" >/dev/null ||
  fail "missing Taskfile diagnostic is missing: $(cat "$work/missing")"

cat >"$work/project/Taskfile.yml" <<'EOF'
version: '3'

vars:
  GREETING: verity

tasks:
  default:
    deps: [prepare]
    cmds:
      - echo "hello {{.GREETING}} from {{.TASK}}"

  prepare:
    cmds:
      - mkdir -p out

  build:
    deps: [prepare]
    sources:
      - input.txt
    generates:
      - out/result.txt
    cmds:
      - tr a-z A-Z < input.txt > out/result.txt
      - wc -c < out/result.txt | tr -d ' ' > out/size.txt

  fails:
    cmds:
      - exit 3
EOF
printf 'taskfile fixture\n' >"$work/project/input.txt"
chmod 644 "$work/project/Taskfile.yml" "$work/project/input.txt"

run --list-all >"$work/list" 2>&1 || fail "list failed: $(cat "$work/list")"
for t in build default fails prepare; do
  grep -E "^\* $t:" "$work/list" >/dev/null || fail "task $t is not listed: $(cat "$work/list")"
done

run >"$work/default" 2>&1 || fail "default task failed: $(cat "$work/default")"
grep -Fx 'hello verity from default' "$work/default" >/dev/null ||
  fail "default task output is wrong: $(cat "$work/default")"

run build >"$work/build" 2>&1 || fail "build task failed: $(cat "$work/build")"
test "$(cat "$work/project/out/result.txt")" = 'TASKFILE FIXTURE' ||
  fail "build output is wrong: $(cat "$work/project/out/result.txt")"
test "$(cat "$work/project/out/size.txt")" = 17 ||
  fail "build size output is wrong: $(cat "$work/project/out/size.txt")"

# Unchanged sources: the checksum recorded in .task makes the second run a no-op.
run build >"$work/rebuild" 2>&1 || fail "second build failed: $(cat "$work/rebuild")"
grep -F 'Task "build" is up to date' "$work/rebuild" >/dev/null ||
  fail "second build was not up to date: $(cat "$work/rebuild")"

# Negative: a failing command propagates a non-zero exit with its task name.
rc=0
run fails >"$work/fails" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'failing task unexpectedly succeeded'
grep -F 'task: Failed to run task "fails"' "$work/fails" >/dev/null ||
  fail "failing task diagnostic is missing: $(cat "$work/fails")"

# Negative: an unknown task is rejected.
rc=0
run does-not-exist >"$work/unknown" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'unknown task unexpectedly succeeded'
grep -F 'Task "does-not-exist" does not exist' "$work/unknown" >/dev/null ||
  fail "unknown task diagnostic is missing: $(cat "$work/unknown")"

printf 'SMOKE PASS image=%s\n' "$image"
