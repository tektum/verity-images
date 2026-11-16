#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
tmp=$(mktemp -d)
logs=$(mktemp -d)
trap 'rm -rf "$tmp" "$logs"' EXIT HUP INT TERM
user=$(id -u):$(id -g)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# Every container runs without a network, so no step can reach Archivista,
# Fulcio, a timestamp authority, or a registry.
witness_in() {
  dir=$1
  shift
  docker run --rm --network none --user "$user" -v "$dir:/work" "$image" "$@"
}

# expect_reject NAME PATTERN ARGS...: witness must exit non-zero and explain why.
expect_reject() {
  name=$1
  pattern=$2
  shift 2
  if witness_in "$tmp" "$@" >"$logs/$name.log" 2>&1; then
    cat "$logs/$name.log" >&2
    fail "$name: witness verify unexpectedly succeeded"
  fi
  grep -F -- "$pattern" "$logs/$name.log" >/dev/null ||
    { cat "$logs/$name.log" >&2; fail "$name: rejection did not report '$pattern'"; }
}

sha256() {
  sha256sum "$1" | awk '{print $1}'
}

b64() {
  base64 <"$1" | tr -d '\n'
}

payload() {
  jq -r .payload "$1" | base64 -d
}

# OCI contract.
config=$(docker image inspect "$image" --format '{{.Config.User}}|{{json .Config.Entrypoint}}|{{.Config.WorkingDir}}')
[ "$config" = '65532|["/usr/bin/witness"]|/work' ] ||
  fail "unexpected OCI user, entrypoint, or working directory: $config"
docker run --rm --network none "$image" version | grep -F witness >/dev/null ||
  fail 'witness version did not run as the default user'

# Keys: the trusted functionary and an untrusted one.
openssl genpkey -algorithm ed25519 -out "$tmp/signer.pem" 2>/dev/null
openssl pkey -in "$tmp/signer.pem" -pubout -out "$tmp/signer.pub"
openssl genpkey -algorithm ed25519 -out "$tmp/rogue.pem" 2>/dev/null
openssl pkey -in "$tmp/rogue.pem" -pubout -out "$tmp/rogue.pub"
printf '%s\n' 'release payload' >"$tmp/source.txt"

# Record a signed attestation collection for a command. The image ships only
# witness, so the attested command is witness itself producing a new file.
witness_in "$tmp" run --step build --attestations environment \
  --signer-file-key-path signer.pem --outfile build.att.json -- \
  /usr/bin/witness sign --infile source.txt --signer-file-key-path signer.pem --outfile artifact.json \
  >"$logs/run.log" 2>&1 || { cat "$logs/run.log" >&2; fail 'witness run failed'; }
[ -s "$tmp/artifact.json" ] || fail 'attested command did not produce artifact.json'
[ "$(jq -r .payloadType "$tmp/build.att.json")" = application/vnd.in-toto+json ] ||
  fail 'attestation is not an in-toto DSSE envelope'
[ "$(jq -r '.signatures | length' "$tmp/build.att.json")" = 1 ] ||
  fail 'attestation envelope is not signed exactly once'
statement=$(payload "$tmp/build.att.json")
[ "$(printf '%s' "$statement" | jq -r .predicateType)" = https://witness.testifysec.com/attestation-collection/v0.1 ] ||
  fail 'attestation predicate is not a witness attestation collection'
printf '%s' "$statement" | jq -e --arg d "$(sha256 "$tmp/artifact.json")" \
  '.subject[] | select(.name == "https://witness.dev/attestations/product/v0.1/file:artifact.json" and .digest.sha256 == $d)' >/dev/null ||
  fail 'attestation subject does not bind the artifact digest'
printf '%s' "$statement" | jq -e \
  '.predicate.attestations[] | select(.type == "https://witness.dev/attestations/command-run/v0.1") | .attestation | select(.exitcode == 0 and .cmd[1] == "sign")' >/dev/null ||
  fail 'attestation does not record the wrapped command and its exit code'

# Signed policy: step build signed by signer.pem, with a Rego check on the command.
keyid=$(sha256 "$tmp/signer.pub")
cat >"$tmp/command.rego" <<'EOF'
package commandrun

import rego.v1

deny contains msg if {
	input.exitcode != 0
	msg := "command exited non-zero"
}

deny contains msg if {
	input.cmd[1] != "sign"
	msg := "unexpected command"
}
EOF
cat >"$tmp/policy.json" <<EOF
{
  "expires": "2099-12-31T00:00:00Z",
  "steps": {
    "build": {
      "name": "build",
      "attestations": [
        {"type": "https://witness.dev/attestations/material/v0.1", "regopolicies": []},
        {"type": "https://witness.dev/attestations/command-run/v0.1",
         "regopolicies": [{"name": "command", "module": "$(b64 "$tmp/command.rego")"}]},
        {"type": "https://witness.dev/attestations/product/v0.1", "regopolicies": []}
      ],
      "functionaries": [{"type": "publickey", "publickeyid": "$keyid"}]
    }
  },
  "publickeys": {
    "$keyid": {"keyid": "$keyid", "key": "$(b64 "$tmp/signer.pub")"}
  }
}
EOF
witness_in "$tmp" sign --infile policy.json --signer-file-key-path signer.pem --outfile policy-signed.json \
  >"$logs/sign.log" 2>&1 || { cat "$logs/sign.log" >&2; fail 'witness sign of the policy failed'; }

witness_in "$tmp" verify --artifactfile artifact.json --attestations build.att.json \
  --policy policy-signed.json --publickey signer.pub >"$logs/verify.log" 2>&1 ||
  { cat "$logs/verify.log" >&2; fail 'witness verify rejected a valid artifact'; }
grep -F 'Verification succeeded' "$logs/verify.log" >/dev/null || fail 'witness verify did not report success'

# Negative cases.
cp "$tmp/artifact.json" "$tmp/tampered.json"
printf ' ' >>"$tmp/tampered.json"
expect_reject tampered-artifact 'Verification failed' \
  verify --artifactfile tampered.json --attestations build.att.json --policy policy-signed.json --publickey signer.pub

# Rebind the signed statement to the tampered artifact without re-signing it.
forged=$(printf '%s' "$statement" | jq -c --arg d "$(sha256 "$tmp/tampered.json")" '.subject[].digest.sha256 = $d' | base64 | tr -d '\n')
jq -c --arg p "$forged" '.payload = $p' "$tmp/build.att.json" >"$tmp/forged.att.json"
expect_reject forged-attestation 'no verifiers present' \
  verify --artifactfile tampered.json --attestations forged.att.json --policy policy-signed.json --publickey signer.pub

expect_reject wrong-policy-key 'failed to verify policy signature' \
  verify --artifactfile artifact.json --attestations build.att.json --policy policy-signed.json --publickey rogue.pub

mkdir "$tmp/rogue"
cp "$tmp/source.txt" "$tmp/rogue.pem" "$tmp/rogue/"
witness_in "$tmp/rogue" run --step build --attestations environment \
  --signer-file-key-path rogue.pem --outfile build.att.json -- \
  /usr/bin/witness sign --infile source.txt --signer-file-key-path rogue.pem --outfile artifact.json \
  >"$logs/rogue-run.log" 2>&1 || { cat "$logs/rogue-run.log" >&2; fail 'witness run with the rogue key failed'; }
expect_reject wrong-signer 'no verifiers present' \
  verify --artifactfile rogue/artifact.json --attestations rogue/build.att.json --policy policy-signed.json --publickey signer.pub

mkdir "$tmp/other"
cp "$tmp/signer.pem" "$tmp/other/"
witness_in "$tmp/other" run --step build --attestations environment \
  --signer-file-key-path signer.pem --outfile build.att.json -- \
  /usr/bin/witness run --step inner --attestations environment --signer-file-key-path signer.pem --outfile artifact.json -- /usr/bin/witness version \
  >"$logs/other-run.log" 2>&1 || { cat "$logs/other-run.log" >&2; fail 'witness run of the unexpected command failed'; }
expect_reject rego-deny 'unexpected command' \
  verify --artifactfile other/artifact.json --attestations other/build.att.json --policy policy-signed.json --publickey signer.pub

printf 'SMOKE PASS image=%s\n' "$image"
