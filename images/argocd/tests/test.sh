#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}

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
printf '%s\n' "$version_output" | grep -F 'argocd: v3.3.14+' >/dev/null \
  || fail 'argocd version check failed'
printf '%s\n' "$version_output" | grep -F \
  'GitCommit: a0a99e187cb6126ef0f3be82d90705513d8f6f3e' >/dev/null \
  || fail 'argocd source commit check failed'
printf '%s\n' "$version_output" | grep -F 'GitTreeState: dirty' >/dev/null \
  || fail 'argocd did not disclose the security-remediated build'

help_output=$(docker run --rm --cpus=4 --network none \
  "$image" argocd-server --help 2>&1)
printf '%s\n' "$help_output" | grep -F 'Run the Argo CD API server' >/dev/null \
  || fail 'argocd-server help check failed'

docker run --rm --cpus=4 --network none "$image" sh -c '
  test -w /home/argocd
  test -d /app/config/ssh
  test -d /app/config/tls
  test -d /app/config/gpg/source
  test -w /app/config/gpg/keys
  helm version --short | grep -F v3.21.3+
  git-lfs version | grep -F git-lfs/3.7.1
  kustomize version
  git --version
  gpg --version >/dev/null
' >/dev/null || fail 'runtime helper or writable path check failed'

if output=$(docker run --rm --cpus=4 --network none \
  "$image" argocd not-a-command 2>&1); then
  fail 'invalid argocd command unexpectedly succeeded'
fi
printf '%s\n' "$output" | grep -F 'unknown command "not-a-command" for "argocd"' >/dev/null \
  || fail 'invalid argocd command did not report the expected error'

printf 'SMOKE PASS image=%s\n' "$image"
