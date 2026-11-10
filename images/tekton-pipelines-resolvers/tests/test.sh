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

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/ko-app/resolvers"]' || fail 'unexpected entrypoint'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'CA bundle environment is missing'

run() {
  docker run --rm --network none --read-only --cpus 2 --memory 512m --pids-limit 256 \
    -e SYSTEM_NAMESPACE=tekton-pipelines "$@"
}

run "$image" --help >"$work/help" 2>&1
grep -F 'Usage of /ko-app/resolvers:' "$work/help" >/dev/null ||
  fail 'resolvers help is missing usage text'
grep -F -- '-kubeconfig' "$work/help" >/dev/null ||
  fail 'resolvers help is missing Kubernetes flags'
grep -F -- '-threads-per-controller' "$work/help" >/dev/null ||
  fail 'resolvers help is missing Tekton flags'

if run "$image" --definitely-invalid >"$work/invalid" 2>&1; then
  fail 'invalid argument unexpectedly succeeded'
fi
grep -F 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'invalid argument diagnostic is missing'

if run "$image" --kubeconfig=/definitely-missing >"$work/kubeconfig" 2>&1; then
  fail 'missing kubeconfig unexpectedly succeeded'
fi
grep -F 'stat /definitely-missing: no such file or directory' "$work/kubeconfig" >/dev/null ||
  fail 'missing kubeconfig diagnostic is missing'

if run "$image" >"$work/nocluster" 2>&1; then
  fail 'start without a kubeconfig or in-cluster environment unexpectedly succeeded'
fi
grep -F 'Error building kubeconfig: failed to create client config: invalid configuration' \
  "$work/nocluster" >/dev/null || fail 'missing cluster configuration diagnostic is missing'

# The git resolver shells out to git, so the image must carry it.
run --entrypoint /usr/bin/git "$image" --version >"$work/git" 2>&1 ||
  fail 'git is not runnable in the resolvers image'
grep -F 'git version' "$work/git" >/dev/null || fail 'git version output is missing'

printf 'SMOKE PASS image=%s\n' "$image"
