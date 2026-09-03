#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
recipe=$(dirname "$0")/../melange.yaml
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)"$/\1/p' "$recipe")
expected_commit=$(sed -n 's/^[[:space:]]*expected-commit:[[:space:]]*\([0-9a-f]*\)$/\1/p' "$recipe" | sed -n '1p')
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
[ -n "$expected_commit" ] || { printf 'source commit not found\n' >&2; exit 1; }

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 999 ] \
  || fail 'image user is not 999'
[ "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/argocd ] \
  || fail 'unexpected working directory'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/tini","--"]' ] || fail 'unexpected image entrypoint'

version_output=$(docker run --rm --cpus=4 --network none \
  "$image" argocd version --client 2>&1)
printf '%s\n' "$version_output" | grep -F "argocd: v$expected_version+" >/dev/null \
  || fail 'argocd version check failed'
printf '%s\n' "$version_output" | grep -F "GitCommit: $expected_commit" >/dev/null \
  || fail 'argocd source commit check failed'
printf '%s\n' "$version_output" | grep -F 'GitTreeState: dirty' >/dev/null \
  || fail 'argocd did not disclose the security-remediated build'

help_output=$(docker run --rm --cpus=4 --network none \
  "$image" argocd-server --help 2>&1)
printf '%s\n' "$help_output" | grep -F 'The API server is a gRPC/REST server' >/dev/null \
  || fail 'argocd-server help check failed'

docker run --rm --cpus=4 --network none "$image" sh -c '
  set -eu

  test -w /home/argocd
  test -w /app/config/ssh
  test -w /app/config/tls
  test -w /app/config/gpg/source
  test -w /app/config/gpg/keys
  helm version --short | grep -F v3.21.3+
  helm version | grep -F "GitTreeState:\"dirty\""
  git-lfs version | grep -F "git-lfs/3.7.1 ("
  kustomize version
  git --version
  gpg --version >/dev/null

  tmp=$(mktemp -d)
  trap "rm -rf \"$tmp\"" EXIT
  git init -q "$tmp"
  git -C "$tmp" lfs install --local >/dev/null
  git -C "$tmp" lfs track "*.bin" >/dev/null
  printf "lfs-smoke\n" >"$tmp/blob.bin"
  git -C "$tmp" add .gitattributes blob.bin
  git -C "$tmp" -c user.name=CI -c user.email=ci@example.invalid commit -qm smoke
  git -C "$tmp" show HEAD:blob.bin | grep -F "version https://git-lfs.github.com/spec/v1"
  rm "$tmp/blob.bin"
  git -C "$tmp" checkout -- blob.bin
  grep -Fx lfs-smoke "$tmp/blob.bin"
' >/dev/null || fail 'runtime helper or writable path check failed'

if output=$(docker run --rm --cpus=4 --network none \
  "$image" argocd not-a-command 2>&1); then
  fail 'invalid argocd command unexpectedly succeeded'
fi
printf '%s\n' "$output" | grep -F 'unknown command "not-a-command" for "argocd"' >/dev/null \
  || fail 'invalid argocd command did not report the expected error'

printf 'SMOKE PASS image=%s\n' "$image"
