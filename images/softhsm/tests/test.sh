#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
config="$here/../apko.yaml"
version=$(sed -n 's/^    - softhsm=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")

# pkcs11-tool is not packaged in Wolfi, so a test-time Wolfi container builds
# it from a pinned OpenSC release. OpenSC does not build against OpenSSL 4 yet,
# so the tool links a private OpenSSL 3 libcrypto through its rpath; symbol
# versions (OPENSSL_3.0.0 against OPENSSL_4.0.0) keep it apart from the
# libcrypto the SoftHSM module uses. The binary runs inside the image under
# test and loads the image's own SoftHSM module.
wolfi_base=cgr.dev/chainguard/wolfi-base@sha256:833c48f1faf32c90e6f9501a2410a9aa28ceb2c594102edd4470053c30efa089
opensc_version=0.27.1
opensc_sha256=976f4a23eaf3397a1a2c3a7aac80bf971a8c3d829c9a79f06145bfaeeae5eca7
opensc_url="https://github.com/OpenSC/OpenSC/releases/download/${opensc_version}/opensc-${opensc_version}.tar.gz"
module=/usr/lib/softhsm/libsofthsm2.so
token_label=verity-smoke
so_pin=12345678
user_pin=87654321

id=$$
tokens="verity-softhsm-tokens-$id"
tools="verity-softhsm-tools-$id"
builder="verity-softhsm-builder-$id"
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$builder" >/dev/null 2>&1 || true
  docker volume rm -f "$tokens" "$tools" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail 'could not read the pinned softhsm version'

# OCI contract.
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/softhsm2-util"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = \
  '["--show-slots"]' || fail 'unexpected command'

docker run --rm --network none "$image" --version >"$work/version" 2>&1 ||
  fail 'softhsm2-util --version failed'
grep -Fx "$version" "$work/version" >/dev/null ||
  fail "softhsm2-util does not report $version: $(cat "$work/version")"

# Upstream softhsm2-util prints usage with status 0 for an unknown option, so
# assert the diagnostic; an action against a missing token must fail.
docker run --rm --network none "$image" --definitely-invalid >"$work/invalid" 2>&1 || true
grep -F "unrecognized option '--definitely-invalid'" "$work/invalid" >/dev/null ||
  fail "invalid option diagnostic is missing: $(cat "$work/invalid")"

rc=0
docker run --rm --network none "$image" --delete-token --token missing \
  >"$work/missing" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'deleting a missing token unexpectedly succeeded'
grep -F 'Could not find a token' "$work/missing" >/dev/null ||
  fail "missing token diagnostic is missing: $(cat "$work/missing")"

# Default command on a fresh token directory: one empty, uninitialized slot.
docker volume create "$tokens" >/dev/null
docker volume create "$tools" >/dev/null
run_hsm() {
  docker run --rm --network none --read-only --cap-drop=ALL \
    -v "$tokens:/var/lib/softhsm/tokens" "$@"
}
run_hsm "$image" >"$work/fresh" 2>&1 || fail "default command failed: $(cat "$work/fresh")"
grep -E '^ +Initialized: +no$' "$work/fresh" >/dev/null ||
  fail "fresh token directory is not uninitialized: $(cat "$work/fresh")"

# A short SO PIN is rejected and leaves the token uninitialized.
rc=0
run_hsm "$image" --init-token --free --label "$token_label" --so-pin 123 \
  --pin "$user_pin" >"$work/short-pin" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'init-token with a 3 character SO PIN unexpectedly succeeded'

run_hsm "$image" --init-token --free --label "$token_label" --so-pin "$so_pin" \
  --pin "$user_pin" >"$work/init" 2>&1 || fail "init-token failed: $(cat "$work/init")"
grep -F "The token has been initialized and is reassigned to slot" "$work/init" >/dev/null ||
  fail "init-token did not report success: $(cat "$work/init")"

run_hsm "$image" --show-slots >"$work/slots" 2>&1 || fail 'show-slots failed after init'
grep -E "^ +Label: +$token_label *$" "$work/slots" >/dev/null ||
  fail "initialized token label missing: $(cat "$work/slots")"
grep -E '^ +Initialized: +yes$' "$work/slots" >/dev/null ||
  fail 'token is not reported as initialized'
grep -E '^ +User PIN init\.: +yes$' "$work/slots" >/dev/null ||
  fail 'user PIN is not reported as initialized'

# Build pkcs11-tool in a Wolfi container from the OpenSC release tarball,
# verified by sha256 before it enters the container.
curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 -o "$work/opensc.tar.gz" "$opensc_url" ||
  fail 'could not download the OpenSC release tarball'
printf '%s  %s\n' "$opensc_sha256" "$work/opensc.tar.gz" | sha256sum -c - >/dev/null ||
  fail 'OpenSC tarball checksum mismatch'
chmod 0755 "$work"
chmod 0644 "$work/opensc.tar.gz"

docker run -d --name "$builder" -v "$work/opensc.tar.gz:/src/opensc.tar.gz:ro" \
  -v "$tools:/opt/opensc" --entrypoint sleep "$wolfi_base" infinity >/dev/null ||
  fail 'could not start the Wolfi builder container'
docker exec "$builder" sh -euc '
  printf "https://packages.wolfi.dev/os\n" >/etc/apk/repositories
  i=0
  until apk add --no-cache -q build-base pkgconf pcsc-lite-dev openssl openssl-3.6-dev; do
    i=$((i + 1))
    [ "$i" -lt 5 ] || exit 1
    sleep 10
  done
  mkdir -p /tmp/build
  tar -xzf /src/opensc.tar.gz -C /tmp/build --strip-components=1
  cd /tmp/build
  ./configure --disable-shared --enable-static --disable-readline --disable-zlib \
    --disable-notify --disable-man --disable-doc --disable-cmocka --disable-tests \
    LDFLAGS=-Wl,-rpath,/opt/opensc/lib
  for dir in common scconf ui pkcs15init sm libopensc pkcs11; do
    make -j"$(nproc)" -C "src/$dir"
  done
  make -j"$(nproc)" -C src/tools pkcs11-tool
  install -d /opt/opensc/lib
  install -m 0755 src/tools/pkcs11-tool /opt/opensc/pkcs11-tool
  cp -L /usr/lib/libcrypto.so.3 /opt/opensc/lib/libcrypto.so.3
' >"$work/build.log" 2>&1 || {
  tail -n 60 "$work/build.log" >&2
  fail 'could not build pkcs11-tool'
}

p11() {
  run_hsm -v "$tools:/opt/opensc:ro" -v "$work:/work:ro" \
    --entrypoint /opt/opensc/pkcs11-tool "$image" --module "$module" "$@"
}

p11 --list-slots >"$work/p11-slots" 2>&1 ||
  fail "pkcs11-tool could not load the SoftHSM module: $(cat "$work/p11-slots")"
grep -F "token label        : $token_label" "$work/p11-slots" >/dev/null ||
  fail "pkcs11-tool does not see the initialized token: $(cat "$work/p11-slots")"

rc=0
p11 --token-label "$token_label" --login --pin 00000000 --list-objects \
  >"$work/wrong-pin" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'login with a wrong user PIN unexpectedly succeeded'
grep -F CKR_PIN_INCORRECT "$work/wrong-pin" >/dev/null ||
  fail "wrong PIN diagnostic is missing: $(cat "$work/wrong-pin")"

printf 'verity softhsm smoke test payload\n' >"$work/message"
printf 'verity softhsm smoke test payload!\n' >"$work/tampered"
chmod 0644 "$work/message" "$work/tampered"

# One EC and one RSA key pair, each generated in its own container so every
# later step proves the token persisted in the volume.
for spec in 01:EC:prime256v1:ECDSA-SHA256 02:rsa:2048:SHA256-RSA-PKCS; do
  key_id=${spec%%:*}
  rest=${spec#*:}
  mechanism=${rest##*:}
  key_type=${rest%:*}
  key_label="smoke-$key_id"

  p11 --token-label "$token_label" --login --pin "$user_pin" --keypairgen \
    --key-type "$key_type" --id "$key_id" --label "$key_label" >"$work/keygen-$key_id" 2>&1 ||
    fail "$key_type key generation failed: $(cat "$work/keygen-$key_id")"

  p11 --token-label "$token_label" --login --pin "$user_pin" --list-objects \
    --type privkey >"$work/privkeys-$key_id" 2>&1 || fail 'listing private keys failed'
  grep -F "label:      $key_label" "$work/privkeys-$key_id" >/dev/null ||
    fail "$key_type private key is not stored on the token: $(cat "$work/privkeys-$key_id")"
  # The private key was generated on the token and can never leave it.
  grep -F 'Access:     sensitive, always sensitive, never extractable, local' \
    "$work/privkeys-$key_id" >/dev/null ||
    fail "$key_type private key is not sensitive and non-extractable: $(cat "$work/privkeys-$key_id")"

  p11 --token-label "$token_label" --login --pin "$user_pin" --sign \
    --mechanism "$mechanism" --id "$key_id" --signature-format openssl \
    --input-file /work/message >"$work/sig-$key_id" 2>"$work/sign-$key_id.log" ||
    fail "$mechanism signing failed: $(cat "$work/sign-$key_id.log")"
  test -s "$work/sig-$key_id" || fail "$mechanism produced an empty signature"
  chmod 0644 "$work/sig-$key_id"

  p11 --token-label "$token_label" --login --pin "$user_pin" --verify \
    --mechanism "$mechanism" --id "$key_id" --signature-format openssl \
    --input-file /work/message --signature-file "/work/sig-$key_id" \
    >"$work/verify-$key_id" 2>&1 || fail "$mechanism token verification failed: $(cat "$work/verify-$key_id")"
  grep -F 'Signature is valid' "$work/verify-$key_id" >/dev/null ||
    fail "$mechanism signature not reported valid: $(cat "$work/verify-$key_id")"

  rc=0
  p11 --token-label "$token_label" --login --pin "$user_pin" --verify \
    --mechanism "$mechanism" --id "$key_id" --signature-format openssl \
    --input-file /work/tampered --signature-file "/work/sig-$key_id" \
    >"$work/tampered-$key_id" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ] && grep -F 'Signature is valid' "$work/tampered-$key_id" >/dev/null; then
    fail "$mechanism signature verified over tampered data"
  fi
  grep -F 'Invalid signature' "$work/tampered-$key_id" >/dev/null ||
    fail "$mechanism tampered verification diagnostic is missing: $(cat "$work/tampered-$key_id")"

  # Verify independently with OpenSSL, outside the token, using the exported
  # public key.
  p11 --token-label "$token_label" --read-object --type pubkey --id "$key_id" \
    >"$work/pub-$key_id.der" 2>"$work/pub-$key_id.log" ||
    fail "public key export failed: $(cat "$work/pub-$key_id.log")"
  docker cp "$work/pub-$key_id.der" "$builder:/tmp/pub.der" >/dev/null
  docker cp "$work/sig-$key_id" "$builder:/tmp/sig" >/dev/null
  docker cp "$work/message" "$builder:/tmp/message" >/dev/null
  docker exec "$builder" openssl dgst -sha256 -keyform DER -verify /tmp/pub.der \
    -signature /tmp/sig /tmp/message >"$work/openssl-$key_id" 2>&1 ||
    fail "OpenSSL rejected the $mechanism signature: $(cat "$work/openssl-$key_id")"
  grep -Fx 'Verified OK' "$work/openssl-$key_id" >/dev/null ||
    fail "OpenSSL did not verify the $mechanism signature"
  docker cp "$work/tampered" "$builder:/tmp/tampered" >/dev/null
  if docker exec "$builder" openssl dgst -sha256 -keyform DER -verify /tmp/pub.der \
    -signature /tmp/sig /tmp/tampered >"$work/openssl-tampered-$key_id" 2>&1; then
    fail "OpenSSL verified the $mechanism signature over tampered data"
  fi
done

printf 'SMOKE PASS image=%s softhsm=%s\n' "$image" "$version"
