#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
# Local Vault dev server, pinned by index digest. It runs only as a test peer on
# an internal network and is never part of the image. Its Alpine-based image
# also stands in for an unrelated application container below.
vault_index=docker.io/hashicorp/vault:2.2.2@sha256:dfa48c2fa2b0099ccb47681ec5c4804bf5aec9d6879ecfee07ad4b92a5427ad6
label="verity-test=vault-env-$$"
network="verity-vault-env-$$"
vault="verity-vault-env-vault-$$"
volume="verity-vault-env-share-$$"
work=$(mktemp -d)

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker volume rm "$volume" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  if docker logs "$vault" >/dev/null 2>&1; then
    printf -- '--- logs: %s\n' "$vault" >&2
    docker logs "$vault" 2>&1 | tail -n 20 >&2 || true
  fi
  exit 1
}

# Upstream image contract: Alpine userland, USER 65534, no entrypoint, the
# binary at /usr/local/bin/vault-env.
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65534 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = null ||
  fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["/bin/sh"]' ||
  fail 'unexpected default command'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'CA bundle environment is missing'

offline() {
  docker run --rm --label "$label" --network none --read-only --cap-drop=ALL \
    --security-opt no-new-privileges "$image" "$@"
}

out=$(offline sh -c 'command -v vault-env') || fail 'vault-env is not on PATH'
test "$out" = /usr/local/bin/vault-env || fail "vault-env resolves to '$out'"

status=0
offline vault-env >"$work/nocommand" 2>&1 || status=$?
test "$status" -ne 0 || fail 'vault-env without a command unexpectedly succeeded'
grep -F 'no command is given' "$work/nocommand" >/dev/null ||
  fail "missing command diagnostic is missing: $(cat "$work/nocommand")"

status=0
offline vault-env /definitely/missing >"$work/nobinary" 2>&1 || status=$?
test "$status" -ne 0 || fail 'a missing child binary unexpectedly succeeded'
grep -F 'binary not found' "$work/nobinary" >/dev/null ||
  fail "missing binary diagnostic is missing: $(cat "$work/nobinary")"

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

# The dev server mounts KV v2 at secret/.
password="pw-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
vault kv put secret/app "password=$password" user=app >/dev/null ||
  fail 'could not write the KV v2 secret'
vault kv get -format=json secret/app | jq -e '.data.metadata.version == 1' >/dev/null ||
  fail 'the dev server did not store a KV v2 secret'

# run_env TOKEN [docker run options...] -- COMMAND...: run the image against Vault.
run_env() {
  token=$1
  shift
  set -- --rm --label "$label" --network "$network" --read-only --cap-drop=ALL \
    --security-opt no-new-privileges -e "VAULT_ADDR=http://$vault:8200" \
    -e "VAULT_TOKEN=$token" -e PLAIN_SETTING=unchanged "$@"
  timeout 60 docker run "$@"
}

run_env "$vault_root" -e 'APP_PASSWORD=vault:secret/data/app#password' \
  -e 'APP_USER=vault:secret/data/app#user' "$image" vault-env env >"$work/env" 2>"$work/env.err" ||
  fail "secret resolution failed: $(cat "$work/env.err")"
grep -Fx "APP_PASSWORD=$password" "$work/env" >/dev/null ||
  fail "APP_PASSWORD was not resolved: $(grep '^APP_' "$work/env" || true)"
grep -Fx 'APP_USER=app' "$work/env" >/dev/null || fail 'APP_USER was not resolved'
grep -Fx 'PLAIN_SETTING=unchanged' "$work/env" >/dev/null ||
  fail 'a plain variable was not passed through'
if grep -E '^VAULT_(ADDR|TOKEN)=' "$work/env" >/dev/null; then
  fail 'Vault client settings leaked into the child environment'
fi
if grep -F "$vault_root" "$work/env" "$work/env.err" >/dev/null; then
  fail 'the Vault token leaked into the child output'
fi

# Negative: a missing secret path fails before the child starts.
status=0
run_env "$vault_root" -e 'APP_PASSWORD=vault:secret/data/missing#password' "$image" \
  vault-env sh -c 'echo CHILD-STARTED' >"$work/missing" 2>&1 || status=$?
test "$status" -ne 0 || fail 'a missing secret unexpectedly succeeded'
if grep -F CHILD-STARTED "$work/missing" >/dev/null; then
  fail 'the child started without its secret'
fi
grep -F 'failed to inject secrets from vault' "$work/missing" >/dev/null ||
  fail "missing secret diagnostic is missing: $(cat "$work/missing")"

# Negative: a missing key in an existing secret fails too.
status=0
run_env "$vault_root" -e 'APP_PASSWORD=vault:secret/data/app#absent' "$image" \
  vault-env sh -c 'echo CHILD-STARTED' >"$work/nokey" 2>&1 || status=$?
test "$status" -ne 0 || fail 'a missing secret key unexpectedly succeeded'
if grep -F CHILD-STARTED "$work/nokey" >/dev/null; then
  fail 'the child started without its secret key'
fi

# Negative: a token Vault rejects fails before the child starts.
status=0
run_env invalid-token -e 'APP_PASSWORD=vault:secret/data/app#password' "$image" \
  vault-env sh -c 'echo CHILD-STARTED' >"$work/badtoken" 2>&1 || status=$?
test "$status" -ne 0 || fail 'an invalid token unexpectedly succeeded'
if grep -F CHILD-STARTED "$work/badtoken" >/dev/null; then
  fail 'the child started with an invalid token'
fi
grep -F 'permission denied' "$work/badtoken" >/dev/null ||
  fail "invalid token diagnostic is missing: $(cat "$work/badtoken")"

# VAULT_IGNORE_MISSING_SECRETS lets the child start without the missing value.
# shellcheck disable=SC2016
out=$(run_env "$vault_root" -e VAULT_IGNORE_MISSING_SECRETS=true \
  -e 'APP_PASSWORD=vault:secret/data/missing#password' "$image" \
  vault-env sh -c 'echo "started:${APP_PASSWORD-unset}"' 2>"$work/ignore.err") ||
  fail "ignoring missing secrets failed: $(cat "$work/ignore.err")"
# vault-env logs to stdout as well; match the child's line exactly.
printf '%s\n' "$out" | grep -Fx 'started:unset' >/dev/null ||
  fail "unexpected output when ignoring missing secrets: $out"

# vault-secrets-webhook contract: its copy-vault-env init container runs this
# exact command with an emptyDir mounted at /vault/, all capabilities dropped,
# and the image user unless the pod sets one. emptyDir is world-writable.
docker volume create --label "$label" "$volume" >/dev/null
docker run --rm --label "$label" --network none --user 0 -v "$volume:/vault/" "$image" \
  chmod 0777 /vault || fail 'could not prepare the shared volume'
docker run --rm --label "$label" --network none --read-only --cap-drop=ALL \
  --security-opt no-new-privileges -v "$volume:/vault/" "$image" \
  sh -c 'cp /usr/local/bin/vault-env /vault/' >"$work/copy" 2>&1 ||
  fail "the webhook init copy command failed: $(cat "$work/copy")"
want=$(offline sha256sum /usr/local/bin/vault-env | cut -d' ' -f1)
got=$(docker run --rm --label "$label" --network none -v "$volume:/vault/:ro" "$image" \
  sh -c 'test -x /vault/vault-env && sha256sum /vault/vault-env' | cut -d' ' -f1)
test -n "$want" && test "$got" = "$want" || fail 'the copied binary differs from the image binary'

# The mutated application container runs /vault/vault-env with its original
# command as arguments, from an unrelated image and an arbitrary user. The
# webhook mounts the shared volume read-write at /vault/ there too.
timeout 60 docker run --rm --label "$label" --network "$network" --read-only --cap-drop=ALL \
  --security-opt no-new-privileges --user 1000:1000 -v "$volume:/vault/" \
  -e "VAULT_ADDR=http://$vault:8200" -e "VAULT_TOKEN=$vault_root" \
  -e 'APP_PASSWORD=vault:secret/data/app#password' \
  --entrypoint /vault/vault-env "$vault_image" env >"$work/copied" 2>"$work/copied.err" ||
  fail "the copied binary failed in another container: $(cat "$work/copied.err")"
grep -Fx "APP_PASSWORD=$password" "$work/copied" >/dev/null ||
  fail 'the copied binary did not resolve APP_PASSWORD'
if grep -E '^VAULT_TOKEN=' "$work/copied" >/dev/null; then
  fail 'the copied binary leaked VAULT_TOKEN to the child'
fi

printf 'SMOKE PASS image=%s\n' "$image"
