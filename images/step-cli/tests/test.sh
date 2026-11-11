#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
# Run as the host user so files created in the bind mount stay removable.
run_as=$(id -u):$(id -g)

cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

step() {
  docker run --rm --network none --user "$run_as" -e STEPPATH=/work/.step \
    -v "$work:/work" -w /work "$image" "$@"
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 1000 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/step"]' || fail 'unexpected entrypoint'

docker run --rm --network none --read-only "$image" version | grep -E 'Smallstep CLI/[0-9]+\.[0-9]+\.[0-9]+' >/dev/null ||
  fail 'step version output is missing'

# Negative: an unknown flag must exit non-zero.
if docker run --rm --network none --read-only "$image" --no-such-flag >/dev/null 2>&1; then
  fail 'unknown flag unexpectedly succeeded'
fi

# Create a self-signed certificate and inspect it.
step certificate create smoke.example.com smoke.crt smoke.key \
  --profile self-signed --subtle --no-password --insecure >/dev/null 2>&1 ||
  fail 'step certificate create failed'
test -s "$work/smoke.crt" || fail 'certificate was not written'
test -s "$work/smoke.key" || fail 'key was not written'
step certificate inspect smoke.crt --short >"$work/inspect" 2>&1 || fail 'step certificate inspect failed'
grep -F 'smoke.example.com' "$work/inspect" >/dev/null || fail 'inspected certificate subject is wrong'
step certificate fingerprint smoke.crt | grep -E '^[0-9a-f]{64}$' >/dev/null ||
  fail 'certificate fingerprint is not a sha256 hex digest'

# Build a small PKI: a root and an intermediate that must verify against it.
step certificate create 'Smoke Root' root.crt root.key --profile root-ca --no-password --insecure >/dev/null 2>&1 ||
  fail 'root CA creation failed'
step certificate create 'Smoke Intermediate' int.crt int.key --profile intermediate-ca \
  --ca root.crt --ca-key root.key --no-password --insecure >/dev/null 2>&1 ||
  fail 'intermediate CA creation failed'
step certificate verify int.crt --roots root.crt >/dev/null 2>&1 || fail 'intermediate does not verify against its root'

# Negative: a different root must not verify the intermediate.
step certificate create 'Other Root' other.crt other.key --profile root-ca --no-password --insecure >/dev/null 2>&1 ||
  fail 'second root creation failed'
if step certificate verify int.crt --roots other.crt >/dev/null 2>&1; then
  fail 'intermediate unexpectedly verified against an unrelated root'
fi

printf 'SMOKE PASS image=%s\n' "$image"
