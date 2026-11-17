#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# Local Vault dev server, pinned by index digest. It runs only on an internal
# network shared with the bank-vaults container.
vault_index=docker.io/hashicorp/vault:2.2.2@sha256:dfa48c2fa2b0099ccb47681ec5c4804bf5aec9d6879ecfee07ad4b92a5427ad6

id=$$
label="verity-test=bank-vaults-$id"
network="verity-bank-vaults-$id"
vault="verity-bank-vaults-vault-$id"
probe="verity-bank-vaults-probe-$id"
work=$(mktemp -d)
# Bind-mount sources exist before the first run so Docker never creates them.
mkdir -p "$work/config" "$work/bin" "$work/out" "$work/tmpl"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  docker logs "$vault" 2>&1 | tail -n 20 >&2 || true
  exit 1
}

cleanup() {
  docker rm -f "$vault" "$probe" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'
expected_commit=$(awk '$1 == "source-commit:" { print $2; exit }' "$here/../melange.yaml")
[ -n "$expected_commit" ] || fail 'could not read the recipe commit'

# OCI contract: upstream USER 65534, no WORKDIR, ENTRYPOINT bank-vaults found
# on PATH in /usr/local/bin.
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65534 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/bank-vaults"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = / ||
  fail 'unexpected working directory'
envs=$(docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image")
printf '%s\n' "$envs" | grep -Fx 'PATH=/usr/local/bin:/usr/bin:/bin' >/dev/null ||
  fail 'PATH does not start with /usr/local/bin'
printf '%s\n' "$envs" | grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'CA bundle environment is missing'

# Version: upstream has no version command, so assert the stamps the binaries
# carry: the Go main module version and VCS revision, and the owning APK.
docker create --name "$probe" "$image" >/dev/null || fail 'cannot create a probe container'
for path in /usr/bin/bank-vaults /usr/bin/template /usr/lib/apk/db/installed; do
  docker cp "$probe:$path" "$work/bin/" || fail "$path is missing"
done
for bin in bank-vaults template; do
  tab=$(printf '\t')
  grep -aE "^mod${tab}github.com/bank-vaults/bank-vaults${tab}v$expected_version(\\+dirty)?${tab}" \
    "$work/bin/$bin" >/dev/null || fail "$bin is not stamped with module v$expected_version"
  grep -aF "vcs.revision=$expected_commit" "$work/bin/$bin" >/dev/null ||
    fail "$bin is not stamped with commit $expected_commit"
  grep -aF 'CGO_ENABLED=1' "$work/bin/$bin" >/dev/null ||
    fail "$bin was not built with cgo as upstream builds it"
done
awk -v want="$expected_version" '
  $0 == "P:verity-bank-vaults" { p = 1; next }
  p && /^V:/ { sub(/^V:/, ""); sub(/-r[0-9]+$/, ""); found = ($0 == want); exit }
  END { exit !found }' "$work/bin/installed" ||
  fail "verity-bank-vaults $expected_version is not installed"

# Every run is hardened and read-only.
run() {
  docker run --rm --read-only --cap-drop=ALL --security-opt=no-new-privileges "$@"
}

# Upstream main() runs flag.Parse() before cobra, so a leading --help only
# prints the Go flag usage; the command reference is `help`.
help=$(run --network none "$image" help 2>&1) || fail "help failed: $help"
for cmd in configure unseal init; do
  printf '%s\n' "$help" | grep -E "^  $cmd " >/dev/null || fail "help does not list $cmd"
done
# The operator overrides the command with bare names resolved through PATH,
# and upstream installs both binaries in /usr/local/bin.
for entry in bank-vaults /usr/local/bin/bank-vaults; do
  run --network none --entrypoint "$entry" "$image" configure --help 2>&1 |
    grep -F 'This configuration is an extension to what is available through the Vault' \
    >/dev/null || fail "$entry configure --help failed"
done

# template renders the Vault server config from VAULT_LOCAL_CONFIG and from
# template file pairs, as the operator's config-templating init container does.
chmod 0777 "$work/out"
# ${ env "..." } is the bank-vaults template syntax, not a shell expansion.
# shellcheck disable=SC2016
run --network none -v "$work/out:/out" -e 'VAULT_LOCAL_CONFIG={"ui": ${ env "UI" }}' \
  -e UI=true --entrypoint template "$image" -file /out/vault.json -mode 0644 ||
  fail 'template from VAULT_LOCAL_CONFIG failed'
test "$(cat "$work/out/vault.json")" = '{"ui": true}' ||
  fail "unexpected VAULT_LOCAL_CONFIG render: $(cat "$work/out/vault.json")"
# shellcheck disable=SC2016
printf 'listener "tcp" { address = "${ env "ADDR" }" }\n' >"$work/tmpl/vault.hcl"
run --network none -v "$work/tmpl:/tmpl:ro" -v "$work/out:/out" -e ADDR=0.0.0.0:8200 \
  --entrypoint /usr/local/bin/template "$image" \
  -template /tmpl/vault.hcl:/out/vault.hcl -mode 0644 || fail 'template file pair failed'
test "$(cat "$work/out/vault.hcl")" = 'listener "tcp" { address = "0.0.0.0:8200" }' ||
  fail "unexpected template file render: $(cat "$work/out/vault.hcl")"
if out=$(run --network none --entrypoint template "$image" -delims bad 2>&1); then
  fail 'template accepted invalid delimiters'
fi
printf '%s\n' "$out" | grep -F 'delims must be two mnemonics' >/dev/null ||
  fail "unexpected invalid delimiter error: $out"

# pull_child INDEX: pull the pinned index by its per-platform child digest,
# verifying the index bytes against the pin first so the pin stays authoritative.
image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
pull_child() {
  ref=${1%%@*}
  ref=${ref%:*}
  raw=$(docker buildx imagetools inspect --raw "$ref@${1#*@}") || fail "cannot inspect $1"
  [ "sha256:$(printf '%s' "$raw" | sha256sum | cut -d' ' -f1)" = "${1#*@}" ] ||
    fail "index digest mismatch for $1"
  child=$(printf '%s' "$raw" | jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') || fail "cannot resolve a child of $1"
  case $child in
    sha256:*) ;;
    *) fail "no unique linux/$image_arch child in $1" ;;
  esac
  docker pull --quiet --platform "linux/$image_arch" "$ref@$child" >/dev/null ||
    fail "cannot pull $ref@$child"
  printf '%s' "$ref@$child"
}
vault_image=$(pull_child "$vault_index")

docker network create --label "$label" --internal "$network" >/dev/null
vault_root=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
docker run -d --name "$vault" --label "$label" --network "$network" -e SKIP_SETCAP=true \
  -e "VAULT_DEV_ROOT_TOKEN_ID=$vault_root" -e VAULT_DEV_LISTEN_ADDRESS=0.0.0.0:8200 \
  "$vault_image" >/dev/null
vault() {
  docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e "VAULT_TOKEN=$vault_root" "$vault" vault "$@"
}
i=0
until vault status >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -le 60 ] || fail 'Vault did not become ready'
  sleep 2
done

# The configuration is mounted read-only and pulls its secrets from the
# environment through the bank-vaults ${env} template function.
cat >"$work/config/vault-config.yml" <<'EOF'
policies:
  - name: verity-reader
    rules: |
      path "verity/data/app" {
        capabilities = ["read"]
      }

secrets:
  - path: verity
    type: kv
    description: Verity bank-vaults smoke test
    options:
      version: 2

auth:
  - type: userpass
    users:
      - username: alice
        password: ${env "VERITY_ALICE_PASSWORD"}
        token_policies: verity-reader

startupSecrets:
  - type: kv
    path: verity/data/app
    data:
      data:
        api_key: ${env "VERITY_API_KEY"}
EOF
cat >"$work/config/invalid.yml" <<'EOF'
secrets:
  - path: verity-broken
    type: verity-no-such-engine
EOF
chmod 0644 "$work/config/vault-config.yml" "$work/config/invalid.yml"
alice_password=$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')
api_key=$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')

configure() {
  run --network "$network" -v "$work/config:/config:ro" \
    -e "VAULT_ADDR=http://$vault:8200" -e "VAULT_TOKEN=$vault_root" \
    -e "VERITY_ALICE_PASSWORD=$alice_password" -e "VERITY_API_KEY=$api_key" \
    "$image" configure --mode dev --once --fatal "$@"
}

# Apply twice: the configurer is idempotent and re-applies on every change.
for attempt in 1 2; do
  out=$(configure --vault-config-file /config/vault-config.yml 2>&1) ||
    fail "configure run $attempt failed: $out"
  printf '%s\n' "$out" | grep -F 'successfully configured vault' >/dev/null ||
    fail "configure run $attempt did not report success: $out"
done

# Verify through the Vault CLI that every section was applied.
vault policy read verity-reader | grep -F 'path "verity/data/app"' >/dev/null ||
  fail 'policy verity-reader was not written'
vault secrets list -format=json |
  jq -e '."verity/" | .type == "kv" and .options.version == "2"' >/dev/null ||
  fail 'kv v2 engine was not mounted at verity/'
vault auth list -format=json | jq -e '."userpass/".type == "userpass"' >/dev/null ||
  fail 'userpass auth was not enabled'
vault read -format=json auth/userpass/users/alice |
  jq -e '.data.token_policies == ["verity-reader"]' >/dev/null ||
  fail 'user alice does not carry the verity-reader policy'
test "$(vault kv get -field=api_key verity/app)" = "$api_key" ||
  fail 'startup secret verity/app was not written'

# End to end: the configured user logs in with the templated password and the
# configured policy grants exactly read on the startup secret.
alice_token=$(vault write -field=token auth/userpass/login/alice password="$alice_password") ||
  fail 'alice cannot log in with the configured password'
as_alice() {
  docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e "VAULT_TOKEN=$alice_token" "$vault" vault "$@"
}
test "$(as_alice kv get -field=api_key verity/app)" = "$api_key" ||
  fail 'alice cannot read the startup secret'
if out=$(as_alice kv put verity/app api_key=overwritten 2>&1); then
  fail 'the verity-reader policy allowed a write'
fi
printf '%s\n' "$out" | grep -F 'permission denied' >/dev/null ||
  fail "unexpected write denial: $out"
if vault write auth/userpass/login/alice password=wrong >/dev/null 2>&1; then
  fail 'alice logged in with a wrong password'
fi

# Negative: an invalid engine type fails the run with --fatal and leaves Vault
# without the mount.
if out=$(configure --vault-config-file /config/invalid.yml 2>&1); then
  fail "configure accepted an unknown secrets engine: $out"
fi
printf '%s\n' "$out" | grep -F 'error configuring vault' >/dev/null ||
  fail "unexpected invalid config error: $out"
if vault secrets list -format=json | jq -e 'has("verity-broken/")' >/dev/null; then
  fail 'the invalid engine was mounted'
fi
test "$(vault kv get -field=api_key verity/app)" = "$api_key" ||
  fail 'the invalid run changed the startup secret'

# Negative: dev mode without VAULT_TOKEN has no root token ($HOME is / with no
# .vault-token) and must not reach Vault.
if out=$(run --network "$network" -v "$work/config:/config:ro" \
  -e "VAULT_ADDR=http://$vault:8200" "$image" configure --mode dev --once --fatal \
  --vault-config-file /config/vault-config.yml 2>&1); then
  fail "configure ran without a root token: $out"
fi
printf '%s\n' "$out" | grep -F 'error creating kv store' >/dev/null ||
  fail "unexpected missing token error: $out"

# Negative: the hsm mode reaches the cgo PKCS#11 loader and fails closed on a
# module path that does not exist, before contacting Vault.
if out=$(run --network none "$image" configure --mode hsm --once --fatal \
  --hsm-module-path /nonexistent/verity-pkcs11.so 2>&1); then
  fail "hsm mode accepted a missing PKCS#11 module: $out"
fi
printf '%s\n' "$out" |
  grep -F 'failed to open p11 module: /nonexistent/verity-pkcs11.so' >/dev/null ||
  fail "unexpected missing PKCS#11 module error: $out"

echo 'bank-vaults smoke test passed'
