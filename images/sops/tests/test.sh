#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
recipe="$(dirname "$0")/../melange.yaml"
version=$(sed -n 's/^  version: "\([0-9.]*\)".*/\1/p' "$recipe")
work=$(mktemp -d)

trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ -n "$version" ] || fail 'could not read the sops version from melange.yaml'
command -v ssh-keygen >/dev/null || fail 'ssh-keygen is required to create throwaway test keys'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/sops"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'
docker image inspect --format '{{json .Config.Env}}' "$image" |
  grep -F '"SOPS_DISABLE_VERSION_CHECK=true"' >/dev/null ||
  fail 'the upstream version check is not disabled'

# With the version check disabled, --version must not reach the network.
docker run --rm --network none "$image" --version >"$work/version" 2>&1 ||
  fail "version failed: $(cat "$work/version")"
test "$(cat "$work/version")" = "sops $version" ||
  fail "version does not report $version: $(cat "$work/version")"

rc=0
docker run --rm --network none "$image" --definitely-invalid >"$work/flag" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'flag provided but not defined: -definitely-invalid' "$work/flag" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/flag")"

# Throwaway SSH keys generated per run serve as age recipients and identities.
mkdir -p "$work/keys" "$work/data"
ssh-keygen -q -t ed25519 -N '' -C verity-sops-test -f "$work/keys/owner" ||
  fail 'could not create the owner test key'
ssh-keygen -q -t ed25519 -N '' -C verity-sops-other -f "$work/keys/other" ||
  fail 'could not create the second test key'
recipient=$(cat "$work/keys/owner.pub")
cat >"$work/data/secrets.yaml" <<'YAML'
database:
  user: verity
  password: verity-plaintext-secret
port: 5432
YAML
chmod -R a+rX "$work"

docker run --rm --network none --read-only -v "$work/data:/work:ro" "$image" \
  encrypt --age "$recipient" secrets.yaml >"$work/secrets.enc.yaml" 2>"$work/encrypt.err" ||
  fail "encryption failed: $(cat "$work/encrypt.err")"
if grep -F 'verity-plaintext-secret' "$work/secrets.enc.yaml" >/dev/null; then
  fail 'the encrypted file contains the plaintext secret'
fi
grep -E '^    password: ENC\[AES256_GCM,data:' "$work/secrets.enc.yaml" >/dev/null ||
  fail "password is not encrypted: $(cat "$work/secrets.enc.yaml")"
grep -F 'recipient: ssh-ed25519 ' "$work/secrets.enc.yaml" >/dev/null ||
  fail 'the SSH recipient is not recorded in the sops metadata'
chmod a+r "$work/secrets.enc.yaml"

docker run --rm --network none --read-only \
  -v "$work/secrets.enc.yaml:/work/secrets.enc.yaml:ro" -v "$work/keys:/keys:ro" \
  -e SOPS_AGE_SSH_PRIVATE_KEY_FILE=/keys/owner "$image" \
  decrypt --extract '["database"]["password"]' secrets.enc.yaml \
  >"$work/password" 2>"$work/decrypt.err" ||
  fail "decryption failed: $(cat "$work/decrypt.err")"
test "$(cat "$work/password")" = verity-plaintext-secret ||
  fail "decrypted unexpected plaintext: $(cat "$work/password")"

docker run --rm --network none --read-only \
  -v "$work/secrets.enc.yaml:/work/secrets.enc.yaml:ro" -v "$work/keys:/keys:ro" \
  -e SOPS_AGE_SSH_PRIVATE_KEY_FILE=/keys/owner "$image" \
  decrypt --output-type json secrets.enc.yaml >"$work/secrets.json" 2>"$work/json.err" ||
  fail "JSON decryption failed: $(cat "$work/json.err")"
grep -F '"port": 5432' "$work/secrets.json" >/dev/null ||
  fail "JSON output is missing the port: $(cat "$work/secrets.json")"

rc=0
docker run --rm --network none --read-only \
  -v "$work/secrets.enc.yaml:/work/secrets.enc.yaml:ro" -v "$work/keys:/keys:ro" \
  -e SOPS_AGE_SSH_PRIVATE_KEY_FILE=/keys/other "$image" \
  decrypt secrets.enc.yaml >"$work/wrong" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'decryption with an unrelated key unexpectedly succeeded'
if grep -F 'verity-plaintext-secret' "$work/wrong" >/dev/null; then
  fail 'an unrelated key revealed the plaintext'
fi

# Tampering with an encrypted value must fail the MAC check.
sed 's/^port: ENC\[AES256_GCM,data:[^,]*/port: ENC[AES256_GCM,data:AAAA/' \
  "$work/secrets.enc.yaml" >"$work/tampered.yaml"
chmod a+r "$work/tampered.yaml"
if cmp -s "$work/secrets.enc.yaml" "$work/tampered.yaml"; then
  fail 'could not tamper with the encrypted port'
fi
rc=0
docker run --rm --network none --read-only \
  -v "$work/tampered.yaml:/work/tampered.yaml:ro" -v "$work/keys:/keys:ro" \
  -e SOPS_AGE_SSH_PRIVATE_KEY_FILE=/keys/owner "$image" \
  decrypt tampered.yaml >"$work/tampered.out" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'a tampered file unexpectedly decrypted'

printf 'SMOKE PASS\n'
