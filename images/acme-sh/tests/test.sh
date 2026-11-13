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

acme() {
  docker run --rm --network none --user "$run_as" -v "$work:/acme.sh" "$image" "$@"
}

user=$(docker image inspect -f '{{.Config.User}}' "$image")
test "$user" = 65532 || fail "image user is $user, want 65532"
entrypoint=$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")
test "$entrypoint" = '["/usr/bin/acme.sh"]' || fail "unexpected entrypoint: $entrypoint"
workdir=$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")
test "$workdir" = /acme.sh || fail "unexpected working directory: $workdir"

version=$(acme --version)
printf '%s\n' "$version" | grep -Eqx 'v3\.1\.[0-9]+' || fail "unexpected version output: $version"

set +e
output=$(acme --no-such-flag 2>&1)
status=$?
set -e
test "$status" -ne 0 || fail 'unknown flag was accepted'
printf '%s\n' "$output" | grep -q 'Unknown parameter: --no-such-flag' \
  || fail "unexpected unknown-flag error: $output"

# A fresh config home lists no certificates.
output=$(acme --list)
test "$(printf '%s\n' "$output" | wc -l)" -eq 1 || fail "fresh --list is not empty: $output"
printf '%s\n' "$output" | grep -q '^Main_Domain' || fail "unexpected --list header: $output"

acme --set-default-ca --server letsencrypt >/dev/null
grep -Fqx "DEFAULT_ACME_SERVER='https://acme-v02.api.letsencrypt.org/directory'" "$work/account.conf" \
  || fail 'default CA was not written to account.conf'
info=$(acme --info)
printf '%s\n' "$info" | grep -Fqx 'LE_WORKING_DIR=/usr/share/acme.sh' || fail "unexpected --info: $info"

# Offline key and CSR generation through the bundled openssl.
acme --create-domain-key -d example.test --keylength ec-256 >/dev/null
acme --create-csr -d example.test -d www.example.test --keylength ec-256 >/dev/null
key="$work/example.test_ecc/example.test.key"
csr="$work/example.test_ecc/example.test.csr"
test -s "$key" || fail 'domain key was not created'
test -s "$csr" || fail 'CSR was not created'
grep -q 'BEGIN EC PRIVATE KEY\|BEGIN PRIVATE KEY' "$key" || fail 'domain key is not PEM'
details=$(docker run --rm --network none --user "$run_as" -v "$work:/acme.sh:ro" \
  --entrypoint openssl "$image" req -in /acme.sh/example.test_ecc/example.test.csr -noout -text -verify 2>&1)
printf '%s\n' "$details" | grep -q 'verify OK' || fail "CSR signature does not verify: $details"
printf '%s\n' "$details" | grep -q 'DNS:example.test, DNS:www.example.test' \
  || fail "CSR SANs missing: $details"
printf '%s\n' "$details" | grep -q 'prime256v1' || fail "CSR key is not ec-256: $details"

# DNS API and deploy hooks ship with the client.
docker run --rm --network none --entrypoint /bin/sh "$image" -c \
  'test -f /usr/share/acme.sh/dnsapi/dns_cf.sh && test -f /usr/share/acme.sh/deploy/docker.sh' \
  || fail 'dnsapi or deploy hooks missing'

printf 'SMOKE PASS image=%s\n' "$image"
