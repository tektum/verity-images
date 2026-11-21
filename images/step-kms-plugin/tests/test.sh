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

kms() {
  docker run --rm --network none --read-only --user "$run_as" \
    -v "$work:/work" -w /work "$image" "$@"
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 1000 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/step-kms-plugin"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/step ||
  fail 'unexpected working directory'

docker run --rm --network none --read-only "$image" version >"$work/version" 2>&1 ||
  fail 'step-kms-plugin version failed'
grep -E '^step-kms-plugin/[0-9]+\.[0-9]+\.[0-9]+ \(linux/(amd64|arm64)\)$' "$work/version" >/dev/null ||
  fail 'step-kms-plugin version output is missing'

# Negative: an unknown flag must exit non-zero.
if docker run --rm --network none --read-only "$image" --no-such-flag >/dev/null 2>&1; then
  fail 'unknown flag unexpectedly succeeded'
fi

# softkms: create an EC key and read its public key back.
kms create softkms:path=/work/ec.pem >"$work/ec-create.pub" 2>"$work/ec-create.err" ||
  fail 'softkms EC key creation failed'
test -s "$work/ec.pem" || fail 'softkms key file was not written'
kms key softkms:path=/work/ec.pem >"$work/ec.pub" || fail 'softkms public key read failed'
grep -Fx -- '-----BEGIN PUBLIC KEY-----' "$work/ec.pub" >/dev/null || fail 'public key is not a PEM public key'
cmp -s "$work/ec-create.pub" "$work/ec.pub" || fail 'public key from create and key differ'
openssl pkey -pubin -in "$work/ec.pub" -noout -text 2>/dev/null | grep -F 'prime256v1' >/dev/null ||
  fail 'default softkms key is not P-256'

# Sign with the KMS key and verify the signature independently with OpenSSL.
printf 'verity step-kms-plugin smoke\n' >"$work/data"
kms sign --in /work/data softkms:path=/work/ec.pem >"$work/sig.b64" || fail 'softkms sign failed'
base64 -d "$work/sig.b64" >"$work/sig.der" || fail 'signature is not base64'
openssl dgst -sha256 -verify "$work/ec.pub" -signature "$work/sig.der" "$work/data" >/dev/null 2>&1 ||
  fail 'OpenSSL rejected the step-kms-plugin signature'
printf 'tampered\n' >"$work/other"
if openssl dgst -sha256 -verify "$work/ec.pub" -signature "$work/sig.der" "$work/other" >/dev/null 2>&1; then
  fail 'signature unexpectedly verified over different data'
fi

# RSA-OAEP round trip through the KMS key.
kms create --kty RSA --size 2048 softkms:path=/work/rsa.pem >/dev/null 2>&1 ||
  fail 'softkms RSA key creation failed'
kms encrypt --oaep --in /work/data softkms:path=/work/rsa.pem >"$work/ct.b64" || fail 'RSA-OAEP encrypt failed'
kms decrypt --oaep --in /work/ct.b64 softkms:path=/work/rsa.pem >"$work/plain" || fail 'RSA-OAEP decrypt failed'
cmp -s "$work/data" "$work/plain" || fail 'RSA-OAEP round trip changed the data'

# Negative: signing with a missing key must fail.
if kms sign --in /work/data softkms:path=/work/missing.pem >/dev/null 2>&1; then
  fail 'signing with a missing key unexpectedly succeeded'
fi

printf 'SMOKE PASS image=%s\n' "$image"
