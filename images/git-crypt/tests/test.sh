#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
config="$here/../apko.yaml"
version=$(sed -n 's/^    - git-crypt=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail 'could not read the pinned git-crypt version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/git-crypt"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

docker run --rm --network none "$image" version >"$work/version" 2>&1 ||
  fail 'version failed'
grep -Fx "git-crypt $version" "$work/version" >/dev/null ||
  fail "version does not report git-crypt $version: $(cat "$work/version")"

rc=0
docker run --rm --network none "$image" definitely-invalid >"$work/invalid" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid command unexpectedly succeeded'
grep -F "'definitely-invalid' is not a git-crypt command" "$work/invalid" >/dev/null ||
  fail 'invalid command diagnostic is missing'

# Outside a repository git-crypt reports the failing git call instead of crashing.
rc=0
docker run --rm --network none --read-only "$image" status >"$work/norepo" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'status outside a repository unexpectedly succeeded'
grep -F 'is this a Git repository?' "$work/norepo" >/dev/null ||
  fail "missing repository diagnostic: $(cat "$work/norepo")"

# The repository lives in a bind mount, so these runs use the caller's UID to
# keep the files removable; git and git-crypt both come from the image.
mkdir -p "$work/repo"
in_dir() {
  dir=$1
  shift
  docker run --rm --network none --read-only --cap-drop=ALL \
    --user "$(id -u):$(id -g)" -e HOME=/tmp -e GIT_CONFIG_NOSYSTEM=1 \
    --tmpfs /tmp:rw,mode=1777 -v "$work:/x" -w "/x/$dir" "$@"
}
run() {
  in_dir repo "$image" "$@"
}
git_() {
  in_dir repo --entrypoint /usr/bin/git "$image" \
    -c user.name=smoke -c user.email=smoke@example.invalid "$@"
}

git_ init -q -b main . || fail 'git init failed'
run init >"$work/init.out" 2>&1 || fail "git-crypt init failed: $(cat "$work/init.out")"
test -s "$work/repo/.git/git-crypt/keys/default" || fail 'init did not write the repository key'

secret="secret payload $(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
printf '%s\n' "$secret" >"$work/repo/secret.txt"
printf 'public payload\n' >"$work/repo/public.txt"
printf 'secret.txt filter=git-crypt diff=git-crypt\n' >"$work/repo/.gitattributes"
cp "$work/repo/secret.txt" "$work/secret.orig"

git_ add .gitattributes secret.txt public.txt || fail 'git add failed'
git_ commit -q -m smoke || fail 'git commit failed'

# The committed blob is ciphertext with the git-crypt header; the public file is not.
git_ cat-file blob HEAD:secret.txt >"$work/blob" || fail 'cat-file failed'
head -c 10 "$work/blob" | od -An -c | tr -d ' \n' | grep -Fx '\0GITCRYPT\0' >/dev/null ||
  fail 'secret.txt was not encrypted in the object store'
grep -F "$secret" "$work/blob" >/dev/null && fail 'plaintext leaked into the object store'
git_ cat-file blob HEAD:public.txt | grep -Fx 'public payload' >/dev/null ||
  fail 'public.txt was unexpectedly filtered'

run status >"$work/status" 2>&1 || fail "status failed: $(cat "$work/status")"
grep -E '^ +encrypted: secret\.txt$' "$work/status" >/dev/null || fail 'status does not list secret.txt as encrypted'
grep -E '^not encrypted: public\.txt$' "$work/status" >/dev/null || fail 'status does not list public.txt as plain'

# Export the key, then lock: the working tree turns back into ciphertext.
run export-key /x/key >"$work/export.out" 2>&1 || fail "export-key failed: $(cat "$work/export.out")"
head -c 12 "$work/key" | od -An -c | tr -d ' \n' | grep -Fx '\0GITCRYPTKEY' >/dev/null ||
  fail 'exported key has no git-crypt key header'
run lock >"$work/lock.out" 2>&1 || fail "lock failed: $(cat "$work/lock.out")"
cmp -s "$work/secret.orig" "$work/repo/secret.txt" && fail 'lock left plaintext in the working tree'
grep -F "$secret" "$work/repo/secret.txt" >/dev/null && fail 'locked file still holds the plaintext'

# A fresh clone without the key only sees ciphertext; the exported key unlocks it.
for clone in clone wrong; do
  git_ clone -q /x/repo "/x/$clone" || fail "git clone into $clone failed"
done
head -c 10 "$work/clone/secret.txt" | od -An -c | tr -d ' \n' | grep -Fx '\0GITCRYPT\0' >/dev/null ||
  fail 'a clone without the key does not hold ciphertext'
in_dir clone "$image" unlock /x/key >"$work/unlock.out" 2>&1 || fail "unlock failed: $(cat "$work/unlock.out")"
cmp -s "$work/secret.orig" "$work/clone/secret.txt" || fail 'unlock did not restore the plaintext'

# Negative: a key generated elsewhere cannot decrypt the files.
in_dir . "$image" keygen /x/wrong.key >/dev/null 2>&1 || fail 'keygen failed'
rc=0
in_dir wrong "$image" unlock /x/wrong.key >"$work/wrong.out" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'unlock with a foreign key unexpectedly succeeded'
grep -F 'encrypted file has been tampered with' "$work/wrong.out" >/dev/null ||
  fail "foreign key diagnostic is missing: $(cat "$work/wrong.out")"
grep -F "$secret" "$work/wrong/secret.txt" >/dev/null 2>&1 && fail 'foreign key decrypted the file'

echo 'SMOKE PASS'
