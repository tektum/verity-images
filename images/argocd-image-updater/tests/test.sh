#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
recipe="$(dirname "$0")/../melange.yaml"
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' "$recipe" | sed -n '1p')
expected_commit=$(sed -n 's/^[[:space:]]*expected-commit:[[:space:]]*\([0-9a-f]\{40\}\)$/\1/p' "$recipe" | sed -n '1p')
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
[ -n "$expected_commit" ] || { printf 'expected commit not found\n' >&2; exit 1; }
workdir=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  rm -rf "$workdir"
}
trap cleanup EXIT INT TERM

# Image contract: non-root user, tini as the init process, the controller behind it.
[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 1000 ] || fail 'image user is not 1000'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/tini","--","/usr/bin/argocd-image-updater"]' ] \
  || fail 'unexpected image entrypoint'
[ "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /app ] || fail 'unexpected working directory'

# The reported version is the pinned upstream release and carries the pinned source commit.
docker run --rm --cpus 4 --cap-drop=ALL --read-only "$image" version --short > "$workdir/version.txt" \
  || fail 'version command failed'
[ "$(cat "$workdir/version.txt")" = "v${expected_version}+$(printf '%.7s' "$expected_commit")" ] \
  || fail "unexpected version: $(cat "$workdir/version.txt")"
docker run --rm --cpus 4 --cap-drop=ALL --read-only "$image" version > "$workdir/version-full.txt" \
  || fail 'full version command failed'
grep -F 'GoCompiler: gc' "$workdir/version-full.txt" >/dev/null || fail 'full version output is missing the Go compiler'
grep -Fx "  GitCommit: $expected_commit" "$workdir/version-full.txt" >/dev/null || fail 'full version output has the wrong source commit'

# The controller command tree is reachable through tini.
docker run --rm --cpus 4 --cap-drop=ALL --read-only "$image" run --help > "$workdir/run-help.txt" 2>&1 \
  || fail 'run --help failed'
grep -F -- '--once' "$workdir/run-help.txt" >/dev/null || fail 'run --help is missing the --once flag'
grep -F -- '--registries-conf-path' "$workdir/run-help.txt" >/dev/null || fail 'run --help is missing the registries flag'

# Bundled helpers the controller shells out to are present and executable.
docker run --rm --cpus 4 --cap-drop=ALL --read-only --entrypoint /usr/bin/git "$image" --version | grep -F 'git version' >/dev/null \
  || fail 'git is missing'
docker run --rm --cpus 4 --cap-drop=ALL --read-only --entrypoint /usr/bin/ssh "$image" -V 2>&1 | grep -F 'OpenSSH' >/dev/null \
  || fail 'ssh is missing'
docker run --rm --cpus 4 --cap-drop=ALL --read-only --entrypoint /usr/bin/gpg "$image" --version | grep -F 'gpg (GnuPG)' >/dev/null \
  || fail 'gpg is missing'
docker run --rm --cpus 4 --cap-drop=ALL --read-only --entrypoint /usr/bin/aws "$image" --version 2>&1 | grep -F 'aws-cli/2' >/dev/null \
  || fail 'aws cli is missing'

# The git credential helper mode is wired into the same binary and refuses to run without a nonce.
if docker run --rm --cpus 4 --cap-drop=ALL --read-only -e ARGOCD_BINARY_NAME=argocd-git-ask-pass \
  --entrypoint /usr/bin/argocd-image-updater "$image" 'Username for https://example.test' > "$workdir/askpass.log" 2>&1; then
  fail 'ask-pass without a nonce unexpectedly succeeded'
fi
grep -F 'ARGOCD_GIT_ASKPASS_NONCE is not set' "$workdir/askpass.log" >/dev/null || fail 'ask-pass nonce diagnostic not found'

# Negative: an unknown flag and an unknown command exit non-zero with a readable error.
if docker run --rm --cpus 4 --cap-drop=ALL --read-only "$image" --no-such-flag > "$workdir/flag.log" 2>&1; then
  fail 'unknown flag unexpectedly succeeded'
fi
grep -F 'unknown flag: --no-such-flag' "$workdir/flag.log" >/dev/null || fail 'unknown flag diagnostic not found'
if docker run --rm --cpus 4 --cap-drop=ALL --read-only "$image" no-such-command > "$workdir/command.log" 2>&1; then
  fail 'unknown command unexpectedly succeeded'
fi
grep -F 'unknown command "no-such-command"' "$workdir/command.log" >/dev/null || fail 'unknown command diagnostic not found'

printf 'SMOKE PASS image=%s\n' "$image"
