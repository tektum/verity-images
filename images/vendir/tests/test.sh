#!/bin/sh
set -eu

# vendir syncs only local sources with no network access: a host directory with
# an exclude pattern, and a local git repository pinned to a tag that is behind
# its branch head. The fixture repository is created with the image's own git.
# Containers run as the invoking user so the host can clean up the work tree.

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^  version: "\([0-9][0-9.]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
user="$(id -u):$(id -g)"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ -n "$expected_version" ] || fail 'vendir package version not found'

inspect() {
  docker image inspect --format "$1" "$image"
}

[ "$(inspect '{{.Config.User}}')" = 65532 ] || fail 'unexpected OCI user'
[ "$(inspect '{{json .Config.Entrypoint}}')" = '["/usr/bin/vendir"]' ] ||
  fail "unexpected entrypoint: $(inspect '{{json .Config.Entrypoint}}')"

version=$(docker run --rm --network none "$image" version)
printf '%s\n' "$version" | grep -q "^vendir version v${expected_version}$" ||
  fail "unexpected vendir version: $version"

run() {
  docker run --rm --network none --user "$user" -e HOME=/tmp -v "$work:/work" "$@"
}

git_fixture() {
  run -w /work/repo --entrypoint /usr/bin/git "$image" \
    -c user.name=verity -c user.email=verity@example.invalid "$@"
}

mkdir -p "$work/src/sub" "$work/repo"
printf 'hello\n' >"$work/src/top.txt"
printf 'nested\n' >"$work/src/sub/inner.txt"
printf 'excluded\n' >"$work/src/sub/debug.log"

git_fixture init -q -b main || fail 'git init failed'
printf 'v1\n' >"$work/repo/VERSION"
git_fixture add VERSION || fail 'git add failed'
git_fixture commit -q -m one || fail 'first commit failed'
git_fixture tag v1.0.0 || fail 'git tag failed'
printf 'v2\n' >"$work/repo/VERSION"
git_fixture commit -q -a -m two || fail 'second commit failed'
tagged=$(git_fixture rev-parse 'v1.0.0^{commit}')

cat >"$work/vendir.yml" <<'EOF'
apiVersion: vendir.k14s.io/v1alpha1
kind: Config
directories:
- path: vendor
  contents:
  - path: local
    directory:
      path: src
    excludePaths:
    - "**/*.log"
  - path: repo
    git:
      url: file:///work/repo
      ref: v1.0.0
EOF

run -w /work "$image" sync >"$work/sync.out" 2>&1 || {
  cat "$work/sync.out" >&2
  fail 'vendir sync failed'
}

[ "$(cat "$work/vendor/local/top.txt")" = hello ] || fail 'directory source top file missing'
[ "$(cat "$work/vendor/local/sub/inner.txt")" = nested ] || fail 'directory source nested file missing'
[ ! -e "$work/vendor/local/sub/debug.log" ] || fail 'excludePaths did not exclude debug.log'
[ "$(cat "$work/vendor/repo/VERSION")" = v1 ] || fail 'git source did not check out tag v1.0.0'
grep -q "sha: ${tagged}" "$work/vendir.lock.yml" || fail 'lock file does not record the tagged commit'

cat >"$work/missing.yml" <<'EOF'
apiVersion: vendir.k14s.io/v1alpha1
kind: Config
directories:
- path: missing-out
  contents:
  - path: local
    directory:
      path: does-not-exist
EOF
if run -w /work "$image" sync -f missing.yml --lock-file missing.lock.yml >/dev/null 2>&1; then
  fail 'sync from a missing directory unexpectedly succeeded'
fi

sed 's/ref: v1.0.0/ref: v9.9.9/' "$work/vendir.yml" >"$work/badref.yml"
if run -w /work "$image" sync -f badref.yml --lock-file badref.lock.yml >/dev/null 2>&1; then
  fail 'sync of an unknown git ref unexpectedly succeeded'
fi

# vendir runs git over SSH through GIT_SSH_COMMAND="ssh ...", so the image must ship an
# ssh client. With no network, an SSH source must fail on the connection, not on a missing ssh.
cat >"$work/ssh.yml" <<'EOF'
apiVersion: vendir.k14s.io/v1alpha1
kind: Config
directories:
- path: ssh-out
  contents:
  - path: repo
    git:
      url: ssh://git@127.0.0.1:1/repo.git
      ref: main
EOF
# ssh needs a passwd entry, so this case runs as the image's own nonroot user in a
# world-writable directory instead of as the invoking host uid.
mkdir -p "$work/ssh"
mv "$work/ssh.yml" "$work/ssh/vendir.yml"
chmod 0777 "$work/ssh"
if docker run --rm --network none -v "$work/ssh:/work" -w /work "$image" sync >"$work/ssh.out" 2>&1; then
  fail 'sync over SSH to a closed port unexpectedly succeeded'
fi
if grep -Eq 'ssh: not found|cannot run ssh|No user exists' "$work/ssh.out"; then
  fail "ssh client is missing from the image: $(cat "$work/ssh.out")"
fi
grep -Eqi 'connect to host 127\.0\.0\.1 port 1|Connection refused|Network is unreachable' "$work/ssh.out" ||
  fail "SSH source did not fail on the connection: $(cat "$work/ssh.out")"

printf 'SMOKE PASS version=%s\n' "$expected_version"
