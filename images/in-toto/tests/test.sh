#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
# Run as the host user so files created in the bind mount stay removable.
run_as=$(id -u):$(id -g)

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

run() {
  docker run --rm --network none --user "$run_as" -v "$work:/work" -w /work "$image" "$@"
}

user=$(docker image inspect -f '{{.Config.User}}' "$image")
test "$user" = 65532 || fail "image user is $user, want 65532"
entrypoint=$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")
test "$entrypoint" = null || fail "unexpected entrypoint: $entrypoint"
cmd=$(docker image inspect -f '{{json .Config.Cmd}}' "$image")
test "$cmd" = '["/usr/bin/in-toto-run","--version"]' || fail "unexpected cmd: $cmd"

# The default command prints the version.
version=$(docker run --rm --network none "$image")
printf '%s\n' "$version" | grep -Eq '^in-toto-run 3\.1\.[0-9]+$' \
  || fail "unexpected version output: $version"
for tool in in-toto-record in-toto-sign in-toto-verify; do
  run "$tool" --version | grep -Eq "^$tool 3\\.1\\.[0-9]+\$" || fail "$tool version mismatch"
done

set +e
output=$(run in-toto-run --step-name probe --no-command --no-such-flag 2>&1)
status=$?
set -e
test "$status" -ne 0 || fail 'unknown flag was accepted'
printf '%s\n' "$output" | grep -q 'unrecognized arguments: --no-such-flag' \
  || fail "unexpected unknown-flag error: $output"

# Generate an owner and a functionary key, then a layout signed by the owner
# that allows one step to create exactly artifact.txt.
cat >"$work/layout.py" <<'EOF'
from cryptography.hazmat.primitives import serialization
from in_toto.models.layout import Layout
from in_toto.models.metadata import Metablock
from securesystemslib.signer import CryptoSigner


def write_key(signer, name):
    private_key = signer._private_key
    with open(f"{name}.pem", "wb") as handle:
        handle.write(private_key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        ))
    with open(f"{name}.pub.pem", "wb") as handle:
        handle.write(private_key.public_key().public_bytes(
            serialization.Encoding.PEM,
            serialization.PublicFormat.SubjectPublicKeyInfo,
        ))


owner = CryptoSigner.generate_ed25519()
functionary = CryptoSigner.generate_ed25519()
write_key(owner, "owner")
write_key(functionary, "functionary")
key = functionary.public_key
layout = Layout.read({
    "_type": "layout",
    "expires": "2099-01-01T00:00:00Z",
    "keys": {key.keyid: {"keyid": key.keyid, **key.to_dict()}},
    "steps": [{
        "_type": "step",
        "name": "write",
        "threshold": 1,
        "pubkeys": [key.keyid],
        "expected_command": [],
        "expected_materials": [],
        "expected_products": [["CREATE", "artifact.txt"], ["DISALLOW", "*"]],
    }],
    "inspect": [],
})
block = Metablock(signed=layout)
block.create_signature(owner)
block.dump("root.layout")
print(key.keyid[:8])
EOF
printf '%s\n' 'release artifact' >"$work/artifact.txt"
chmod -R a+rwX "$work"

keyid=$(run /opt/chainguard/in-toto/bin/python layout.py)
run in-toto-run --step-name write --signing-key functionary.pem \
  --products artifact.txt --no-command
link="$work/write.$keyid.link"
test -f "$link" || fail "missing link metadata write.$keyid.link"
grep -q '"artifact.txt"' "$link" || fail 'link does not record artifact.txt'

run in-toto-verify --layout root.layout --verification-keys owner.pub.pem \
  || fail 'valid supply chain did not verify'

set +e
output=$(run in-toto-verify --layout root.layout --verification-keys functionary.pub.pem 2>&1)
status=$?
set -e
test "$status" -ne 0 || fail 'layout verified with a non-owner key'
printf '%s\n' "$output" | grep -q 'SignatureVerificationError' \
  || fail "unexpected wrong-key error: $output"

# Tamper with the recorded product hash; the functionary signature must break.
sed 's/"sha256": "[0-9a-f]*"/"sha256": "0000000000000000000000000000000000000000000000000000000000000000"/' \
  "$link" >"$work/tampered" && cat "$work/tampered" >"$link"
set +e
output=$(run in-toto-verify --layout root.layout --verification-keys owner.pub.pem 2>&1)
status=$?
set -e
test "$status" -ne 0 || fail 'tampered link verified'
printf '%s\n' "$output" | grep -q 'ThresholdVerificationError' \
  || fail "unexpected tampered-link error: $output"

printf 'SMOKE PASS image=%s\n' "$image"
