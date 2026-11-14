#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
melange="$(dirname "$0")/../melange.yaml"
version=$(sed -n 's/^  version: "\([0-9.]*\)".*/\1/p' "$melange")
server="verity-cfssl-serve-$$"
work=$(mktemp -d)

cleanup() {
  docker rm -f "$server" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

run() {
  docker run --rm --network none --read-only -v "$work:/work" "$@"
}

[ -n "$version" ] || fail 'could not read the pinned cfssl version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/cfssl"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["--help"]' ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

# The work directory is a bind mount the non-root user must write to.
chmod 0777 "$work"

run "$image" version >"$work/version" 2>&1 || fail 'version failed'
grep -Fx "Version: $version" "$work/version" >/dev/null ||
  fail "version does not report $version: $(cat "$work/version")"

rc=0
run "$image" definitely-invalid >"$work/invalid" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'an unknown command unexpectedly succeeded'

for cmd in cfssl-bundle cfssl-certinfo cfssl-newkey cfssl-scan cfssljson mkbundle multirootca; do
  rc=0
  run --entrypoint "/usr/bin/$cmd" "$image" -h >"$work/$cmd.help" 2>&1 || rc=$?
  grep -i 'usage' "$work/$cmd.help" >/dev/null ||
    fail "$cmd does not print usage (exit $rc): $(cat "$work/$cmd.help")"
done

cat >"$work/ca-csr.json" <<'JSON'
{"CN": "Verity Smoke CA", "key": {"algo": "ecdsa", "size": 256}, "names": [{"O": "Verity"}]}
JSON
cat >"$work/leaf-csr.json" <<'JSON'
{"CN": "verity.test", "hosts": ["verity.test", "127.0.0.1"], "key": {"algo": "ecdsa", "size": 256}}
JSON
cat >"$work/config.json" <<'JSON'
{"signing": {"default": {"expiry": "24h"}, "profiles": {"server": {"expiry": "24h",
  "usages": ["signing", "key encipherment", "server auth"]}}}}
JSON
chmod 0644 "$work"/*.json

# Initialise a CA and split the JSON with cfssljson, all inside the image.
run "$image" gencert -initca ca-csr.json >"$work/ca.json" 2>"$work/ca.err" ||
  fail "gencert -initca failed: $(cat "$work/ca.err")"
run -i --entrypoint /usr/bin/cfssljson "$image" -bare ca <"$work/ca.json" ||
  fail 'cfssljson could not split the CA response'
test -s "$work/ca.pem" && test -s "$work/ca-key.pem" && test -s "$work/ca.csr" ||
  fail 'cfssljson did not write ca.pem, ca-key.pem and ca.csr'

run "$image" gencert -ca ca.pem -ca-key ca-key.pem -config config.json -profile server \
  leaf-csr.json >"$work/leaf.json" 2>"$work/leaf.err" ||
  fail "signing the leaf failed: $(cat "$work/leaf.err")"
run -i --entrypoint /usr/bin/cfssljson "$image" -bare leaf <"$work/leaf.json" ||
  fail 'cfssljson could not split the leaf response'

openssl x509 -in "$work/ca.pem" -noout -text >"$work/ca.txt"
grep -F 'CA:TRUE' "$work/ca.txt" >/dev/null || fail 'the CA certificate is not a CA'
openssl verify -CAfile "$work/ca.pem" "$work/leaf.pem" >"$work/verify" 2>&1 ||
  fail "openssl rejected the leaf: $(cat "$work/verify")"
openssl x509 -in "$work/leaf.pem" -noout -text >"$work/leaf.txt"
grep -F 'DNS:verity.test, IP Address:127.0.0.1' "$work/leaf.txt" >/dev/null ||
  fail "the leaf SANs are wrong: $(grep -A1 'Subject Alternative Name' "$work/leaf.txt")"
grep -F 'TLS Web Server Authentication' "$work/leaf.txt" >/dev/null ||
  fail 'the server profile did not set serverAuth'
grep -E 'Subject: .*CN *= *verity.test' "$work/leaf.txt" >/dev/null ||
  fail 'the leaf subject is wrong'

run "$image" certinfo -cert leaf.pem >"$work/certinfo.json" 2>&1 ||
  fail "certinfo failed: $(cat "$work/certinfo.json")"
jq -e '.subject.common_name == "verity.test" and .issuer.common_name == "Verity Smoke CA"' \
  "$work/certinfo.json" >/dev/null || fail "certinfo reported the wrong names: $(cat "$work/certinfo.json")"

# A second, unrelated CA must not validate the leaf.
run "$image" gencert -initca ca-csr.json >"$work/other.json" 2>/dev/null
jq -r .cert "$work/other.json" >"$work/other.pem"
if openssl verify -CAfile "$work/other.pem" "$work/leaf.pem" >/dev/null 2>&1; then
  fail 'the leaf unexpectedly validated against an unrelated CA'
fi

# Signing with a key that does not match the CA certificate must fail.
jq -r .key "$work/other.json" >"$work/other-key.pem"
chmod 0644 "$work/other-key.pem"
rc=0
run "$image" gencert -ca ca.pem -ca-key other-key.pem -config config.json \
  leaf-csr.json >"$work/mismatch" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'signing with a mismatched CA key unexpectedly succeeded'

# The API server signs a CSR from the same CA.
docker run -d --name "$server" --read-only -p 127.0.0.1::8888 -v "$work:/work:ro" "$image" \
  serve -address 0.0.0.0 -port 8888 -ca ca.pem -ca-key ca-key.pem -config config.json >/dev/null
port=$(docker port "$server" 8888/tcp | sed -n '1s/.*://p')
attempts=0
until curl --fail --silent --max-time 5 -d '{}' "http://127.0.0.1:$port/api/v1/cfssl/info" \
  >"$work/info.json" 2>/dev/null; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || { docker logs "$server" >&2; fail 'cfssl serve did not become ready'; }
  sleep 1
done
jq -e '.success == true' "$work/info.json" >/dev/null || fail "info failed: $(cat "$work/info.json")"
jq -r .result.certificate "$work/info.json" >"$work/info.pem"
test "$(openssl x509 -in "$work/info.pem" -noout -fingerprint -sha256)" = \
  "$(openssl x509 -in "$work/ca.pem" -noout -fingerprint -sha256)" ||
  fail 'the API served a different CA certificate'

jq -n --rawfile csr "$work/leaf.csr" '{certificate_request: $csr, profile: "server"}' >"$work/sign.json"
curl --fail --silent --max-time 10 -d @"$work/sign.json" "http://127.0.0.1:$port/api/v1/cfssl/sign" \
  >"$work/signed.json" || fail 'the sign API call failed'
jq -e '.success == true' "$work/signed.json" >/dev/null || fail "sign failed: $(cat "$work/signed.json")"
jq -r .result.certificate "$work/signed.json" >"$work/api-leaf.pem"
openssl verify -CAfile "$work/ca.pem" "$work/api-leaf.pem" >/dev/null 2>&1 ||
  fail 'openssl rejected the certificate signed by the API'

printf 'SMOKE PASS\n'
