#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
config="$here/../apko.yaml"
version=$(sed -n 's/^    - git=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail 'could not read the pinned git version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/git"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

docker run --rm --network none "$image" --version >"$work/version" 2>&1 ||
  fail 'version failed'
grep -Fx "git version $version" "$work/version" >/dev/null ||
  fail "version does not report git $version: $(cat "$work/version")"

rc=0
docker run --rm --network none "$image" definitely-invalid >"$work/invalid" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid command unexpectedly succeeded'
grep -F "'definitely-invalid' is not a git command" "$work/invalid" >/dev/null ||
  fail 'invalid command diagnostic is missing'

# Outside a repository git reports the missing repository instead of crashing.
rc=0
docker run --rm --network none --read-only "$image" status >"$work/norepo" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'status outside a repository unexpectedly succeeded'
grep -F 'not a git repository' "$work/norepo" >/dev/null ||
  fail "missing repository diagnostic: $(cat "$work/norepo")"

# The repositories live in a bind mount, so these runs use the caller's UID to
# keep the files removable; every git process comes from the image.
in_dir() {
  dir=$1
  shift
  docker run --rm --network none --read-only --cap-drop=ALL \
    --user "$(id -u):$(id -g)" -e HOME=/tmp -e GIT_CONFIG_NOSYSTEM=1 \
    --tmpfs /tmp:rw,mode=1777 -v "$work:/x" -w "/x/$dir" "$image" \
    -c user.name=smoke -c user.email=smoke@example.invalid \
    -c init.defaultBranch=main -c protocol.file.allow=always "$@"
}

in_dir . init -q --bare remote.git || fail 'bare repository init failed'
in_dir . clone -q /x/remote.git clone-a >"$work/clone-a.out" 2>&1 ||
  fail "clone of the empty bare repository failed: $(cat "$work/clone-a.out")"

printf 'hello from the verity git image\n' >"$work/clone-a/README"
in_dir clone-a add README || fail 'git add failed'
in_dir clone-a commit -q -m 'smoke: first commit' || fail 'git commit failed'
in_dir clone-a push -q origin HEAD:main >"$work/push.out" 2>&1 ||
  fail "push to the bare repository failed: $(cat "$work/push.out")"

head=$(in_dir clone-a rev-parse HEAD) || fail 'rev-parse in the working clone failed'
remote_head=$(in_dir remote.git rev-parse refs/heads/main) ||
  fail 'bare repository has no main branch after push'
test "$head" = "$remote_head" ||
  fail "bare repository main $remote_head does not match pushed commit $head"

in_dir . clone -q /x/remote.git clone-b >"$work/clone-b.out" 2>&1 ||
  fail "clone of the pushed repository failed: $(cat "$work/clone-b.out")"
grep -Fx 'hello from the verity git image' "$work/clone-b/README" >/dev/null ||
  fail 'fresh clone does not contain the pushed file'
subject=$(in_dir clone-b log -1 --format=%s) || fail 'git log in the fresh clone failed'
test "$subject" = 'smoke: first commit' || fail "unexpected commit subject: $subject"

# A non-fast-forward push must be rejected by the receiving side.
printf 'diverged\n' >"$work/clone-b/README"
in_dir clone-b commit -q -a -m 'smoke: second commit' || fail 'second commit failed'
in_dir clone-b push -q origin HEAD:main || fail 'fast-forward push failed'
printf 'stale\n' >"$work/clone-a/README"
in_dir clone-a commit -q -a -m 'smoke: stale commit' || fail 'stale commit failed'
rc=0
in_dir clone-a push origin HEAD:main >"$work/reject.out" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'non-fast-forward push unexpectedly succeeded'
grep -F 'rejected' "$work/reject.out" >/dev/null ||
  fail "missing non-fast-forward rejection: $(cat "$work/reject.out")"

in_dir remote.git fsck --strict >"$work/fsck.out" 2>&1 ||
  fail "bare repository failed fsck: $(cat "$work/fsck.out")"

# The HTTPS transport helper ships with the image for remote clones.
rc=0
docker run --rm --network none --entrypoint /usr/libexec/git-core/git-remote-https \
  "$image" >"$work/https.out" 2>&1 || rc=$?
grep -F 'remote-curl: usage' "$work/https.out" >/dev/null ||
  fail "HTTPS transport helper is missing: $(cat "$work/https.out")"

echo 'SMOKE PASS'
