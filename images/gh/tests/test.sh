#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)

cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

gh_run() {
  docker run --rm --network none --read-only --tmpfs /home/nonroot:uid=65532,gid=65532 "$image" "$@"
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/gh"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'

gh_run --version >"$work/version" || fail 'gh --version failed'
grep -E '^gh version [0-9]+\.[0-9]+\.[0-9]+ \([0-9]{4}-[0-9]{2}-[0-9]{2}\)$' "$work/version" >/dev/null ||
  fail 'gh version output is malformed'
grep -E '^https://github\.com/cli/cli/releases/tag/v[0-9]+\.[0-9]+\.[0-9]+$' "$work/version" >/dev/null ||
  fail 'gh release URL is missing'

# Negative: an unknown command must exit non-zero.
if gh_run no-such-command >/dev/null 2>&1; then
  fail 'unknown command unexpectedly succeeded'
fi

# Negative: without credentials, auth status must fail and say so.
if gh_run auth status >"$work/auth" 2>&1; then
  fail 'auth status unexpectedly succeeded without credentials'
fi
grep -F 'not logged in' "$work/auth" >/dev/null || fail 'auth status did not report missing login'

# Configuration persists in a writable home and is read back.
docker run --rm --network none -v "$work:/work" --user "$(id -u):$(id -g)" -e GH_CONFIG_DIR=/work/gh \
  "$image" config set git_protocol ssh || fail 'gh config set failed'
test "$(docker run --rm --network none -v "$work:/work" --user "$(id -u):$(id -g)" -e GH_CONFIG_DIR=/work/gh \
  "$image" config get git_protocol)" = ssh || fail 'gh config value did not persist'
grep -F 'git_protocol: ssh' "$work/gh/config.yml" >/dev/null || fail 'config file was not written'

# Negative: with no network, an API call must fail rather than hang or succeed.
if docker run --rm --network none -e GH_TOKEN=invalid "$image" api /rate_limit >/dev/null 2>&1; then
  fail 'gh api unexpectedly succeeded without network'
fi

gh_run api --help | grep -F 'Makes an authenticated HTTP request to the GitHub API' >/dev/null ||
  fail 'gh api help is missing'

# Negative: an unauthenticated API call must fail with the documented login hint.
if gh_run api user >"$work/api" 2>&1; then
  fail 'unauthenticated gh api user unexpectedly succeeded'
fi
grep -F 'gh auth login' "$work/api" >/dev/null || fail 'unauthenticated gh api did not point to gh auth login'

# git ships for repository commands.
docker run --rm --network none --entrypoint /usr/bin/git "$image" --version |
  grep -E '^git version [0-9]+\.' >/dev/null || fail 'git is missing'

# Negative: setting up the git credential helper needs a login.
if gh_run auth setup-git --hostname github.com >/dev/null 2>&1; then
  fail 'auth setup-git unexpectedly succeeded without credentials'
fi

# gh registers itself as the git credential helper; git runs that helper through
# /bin/sh, so this also proves the shell the helper needs is present. The token is
# a dummy value that never leaves the container network sandbox.
mkdir "$work/home"
as_host() {
  docker run --rm --network none --user "$(id -u):$(id -g)" -v "$work/home:/work/home" \
    -e HOME=/work/home -e GH_TOKEN=smoke-dummy-token -e GIT_TERMINAL_PROMPT=0 "$@"
}
as_host "$image" auth setup-git --hostname github.com || fail 'auth setup-git failed with a token'
grep -F 'gh auth git-credential' "$work/home/.gitconfig" >/dev/null ||
  fail 'credential helper was not written to .gitconfig'
printf 'protocol=https\nhost=github.com\n\n' |
  as_host -i --entrypoint /usr/bin/git "$image" credential fill >"$work/credential" ||
  fail 'git credential fill through the gh helper failed'
grep -Fx 'password=smoke-dummy-token' "$work/credential" >/dev/null ||
  fail 'gh helper did not return the token to git'

printf 'SMOKE PASS image=%s\n' "$image"
