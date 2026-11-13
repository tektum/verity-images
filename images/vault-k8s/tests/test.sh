#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d)

trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/vault-k8s"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'CA bundle environment is missing'

version=$(docker run --rm --network none --read-only "$image" version)
[ "$version" = "vault-k8s v$expected_version" ] ||
  fail "version is '$version', expected 'vault-k8s v$expected_version'"

docker run --rm --network none --read-only "$image" --help >"$work/help" 2>&1 || true
grep -F 'agent-inject' "$work/help" >/dev/null || fail 'help does not list agent-inject'

docker run --rm --network none --read-only "$image" agent-inject -h >"$work/inject-help" 2>&1 || true
for flag in -listen -tls-auto -tls-cert-file -tls-key-file -vault-address -vault-image -vault-auth-type; do
  grep -F -e "  $flag" "$work/inject-help" >/dev/null || fail "agent-inject help is missing $flag"
done

if docker run --rm --network none --read-only "$image" agent-inject --definitely-invalid \
  >"$work/invalid" 2>&1; then
  fail 'invalid argument unexpectedly succeeded'
fi
grep -F 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'invalid argument diagnostic is missing'

if docker run --rm --network none --read-only "$image" bogus-command \
  >"$work/bogus" 2>&1; then
  fail 'unknown subcommand unexpectedly succeeded'
fi

if docker run --rm --network none --read-only "$image" agent-inject \
  >"$work/novault" 2>&1; then
  fail 'agent-inject without a Vault address unexpectedly succeeded'
fi
grep -F 'No Vault service configured' "$work/novault" >/dev/null ||
  fail "missing Vault address diagnostic is missing: $(cat "$work/novault")"

# The Vault address may also come from the environment, as the Helm chart sets it.
if docker run --rm --network none --read-only \
  -e AGENT_INJECT_VAULT_ADDR=https://vault.example.invalid:8200 "$image" agent-inject \
  >"$work/nocluster" 2>&1; then
  fail 'agent-inject outside a cluster unexpectedly succeeded'
fi
grep -F 'Error loading in-cluster K8S config: unable to load in-cluster configuration, KUBERNETES_SERVICE_HOST and KUBERNETES_SERVICE_PORT must be defined' \
  "$work/nocluster" >/dev/null || fail "in-cluster diagnostic is missing: $(cat "$work/nocluster")"

if docker run --rm --network none --read-only "$image" agent-inject \
  -vault-address=https://vault.example.invalid:8200 -tls-min-version=tls9 \
  >"$work/badtls" 2>&1; then
  fail 'agent-inject with an invalid TLS version unexpectedly succeeded'
fi

printf 'SMOKE PASS image=%s\n' "$image"
