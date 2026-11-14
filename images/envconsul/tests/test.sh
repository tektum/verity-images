#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
recipe_value() {
  awk -v key="$1" '$1 == key { gsub(/"/, "", $2); print $2; exit }' "$here/../melange.yaml"
}
version=$(recipe_value version:)
commit=$(recipe_value source-commit:)
# Local Consul and Vault dev servers, pinned by index digest. They run only as
# test peers on an internal network and are never part of the image.
consul_index=docker.io/hashicorp/consul:2.1.0@sha256:259fd02f2544fe1aa03fa49efd3b105c8dd67106d710a72f5e898110266356f7
vault_index=docker.io/hashicorp/vault:2.2.2@sha256:dfa48c2fa2b0099ccb47681ec5c4804bf5aec9d6879ecfee07ad4b92a5427ad6
label="verity-test=envconsul-$$"
network="verity-envconsul-$$"
consul="verity-envconsul-consul-$$"
vault="verity-envconsul-vault-$$"
watcher="verity-envconsul-watch-$$"
work=$(mktemp -d)

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  for name in "$watcher" "$consul" "$vault"; do
    docker logs "$name" >/dev/null 2>&1 || continue
    printf -- '--- logs: %s\n' "$name" >&2
    docker logs "$name" 2>&1 | tail -n 20 >&2 || true
  done
  exit 1
}

[ -n "$version" ] || fail 'could not read the recipe version'
[ -n "$commit" ] || fail 'could not read the recipe source commit'
short=$(printf '%s' "$commit" | cut -c1-7)

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/envconsul"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'

offline() {
  docker run --rm --label "$label" --network none --read-only --cap-drop=ALL "$image" "$@"
}

# stdout only: docker prints a platform mismatch warning on stderr for emulated arm64 runs.
out=$(offline -version) || fail 'version failed'
test "$out" = "envconsul v$version ($short)" || fail "unexpected version: $out"

status=0
offline -definitely-invalid >"$work/invalid" 2>&1 || status=$?
test "$status" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"

status=0
offline -prefix app/config >"$work/nocommand" 2>&1 || status=$?
test "$status" -ne 0 || fail 'a run without a command unexpectedly succeeded'
grep -F 'No command given' "$work/nocommand" >/dev/null ||
  fail "missing command diagnostic is missing: $(cat "$work/nocommand")"

# Negative: with an unreachable Consul, envconsul keeps waiting for the data
# and never starts the child without it. SIGINT, its kill signal, stops it.
mkdir -p "$work/out"
chmod 777 "$work/out"
unreachable="verity-envconsul-unreachable-$$"
docker run -d --name "$unreachable" --label "$label" --network none --read-only --cap-drop=ALL \
  -v "$work/out:/out" "$image" -consul-addr 127.0.0.1:9 -prefix app/config 'touch /out/started' \
  >/dev/null
sleep 8
test "$(docker inspect -f '{{.State.Running}}' "$unreachable")" = true ||
  fail "envconsul gave up on an unreachable Consul: $(docker logs "$unreachable" 2>&1)"
test ! -e "$work/out/started" || fail 'the child started without Consul data'
docker kill -s INT "$unreachable" >/dev/null
i=0
until [ "$(docker inspect -f '{{.State.Running}}' "$unreachable")" = false ]; do
  i=$((i + 1))
  [ "$i" -le 20 ] || fail 'envconsul ignored SIGINT'
  sleep 1
done
test "$(docker inspect -f '{{.State.ExitCode}}' "$unreachable")" = 12 ||
  fail "interrupted envconsul exited $(docker inspect -f '{{.State.ExitCode}}' "$unreachable"), want 12"
docker logs "$unreachable" 2>&1 | grep -Fx 'Cleaning up...' >/dev/null ||
  fail "interrupt cleanup message is missing: $(docker logs "$unreachable" 2>&1)"
test ! -e "$work/out/started" || fail 'the child started after the interrupt'

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
consul_image=$(pull_child "$consul_index")
vault_image=$(pull_child "$vault_index")

docker network create --label "$label" --internal "$network" >/dev/null
docker run -d --name "$consul" --label "$label" --network "$network" "$consul_image" \
  agent -dev -client 0.0.0.0 >/dev/null
vault_root=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
docker run -d --name "$vault" --label "$label" --network "$network" -e SKIP_SETCAP=true \
  -e "VAULT_DEV_ROOT_TOKEN_ID=$vault_root" -e VAULT_DEV_LISTEN_ADDRESS=0.0.0.0:8200 \
  "$vault_image" >/dev/null

kv() {
  docker exec "$consul" consul kv put "$1" "$2" >/dev/null || fail "could not write $1"
}
vault() {
  docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e "VAULT_TOKEN=$vault_root" "$vault" vault "$@"
}
i=0
until docker exec "$consul" consul kv put verity/ready 1 >/dev/null 2>&1 && vault status >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -le 60 ] || fail 'Consul or Vault did not become ready'
  sleep 2
done

kv app/config/db-host db.internal
kv app/config/max_conns 25
kv app/config/log_level debug

envconsul() {
  timeout 60 docker run --rm --label "$label" --network "$network" --read-only --cap-drop=ALL \
    "$image" -consul-addr "$consul:8500" "$@"
}

# Keys under the prefix become variables of the child, alongside its own environment.
envconsul -prefix app/config -once env >"$work/env" 2>&1 || fail "env run failed: $(cat "$work/env")"
for line in db-host=db.internal max_conns=25 log_level=debug HOME=/home/nonroot; do
  grep -Fx "$line" "$work/env" >/dev/null || fail "child environment lacks $line: $(cat "$work/env")"
done

# -sanitize and -upcase make shell-safe names; -pristine drops everything else.
envconsul -prefix app/config -sanitize -upcase -pristine -once env >"$work/pristine" 2>&1 ||
  fail "pristine run failed: $(cat "$work/pristine")"
printf 'DB_HOST=db.internal\nLOG_LEVEL=debug\nMAX_CONNS=25\n' >"$work/want"
sort "$work/pristine" | cmp -s - "$work/want" || fail "unexpected pristine environment: $(cat "$work/pristine")"

# A shell command line runs under /bin/sh and its exit status is propagated.
status=0
# shellcheck disable=SC2016 # expanded by the child's /bin/sh, not here
envconsul -prefix app/config -sanitize -upcase 'test "$MAX_CONNS" = 25 && exit 7' >"$work/exit" 2>&1 ||
  status=$?
test "$status" = 7 || fail "child exit status 7 came back as $status: $(cat "$work/exit")"
grep -F 'unexpected exit from subprocess (7)' "$work/exit" >/dev/null ||
  fail "child exit diagnostic is missing: $(cat "$work/exit")"

# Watch mode: a KV change stops the child with the kill signal (SIGINT) and
# restarts it with the new value; a stop signal (SIGTERM) is forwarded to it.
docker run -d --name "$watcher" --label "$label" --network "$network" --read-only --cap-drop=ALL \
  -v "$work/out:/out" "$image" -consul-addr "$consul:8500" -prefix app/config \
  'trap "echo int >>/out/levels; exit 0" INT; trap "echo term >>/out/levels; exit 0" TERM
   echo "$log_level" >>/out/levels; sleep 600 & wait' \
  >/dev/null
i=0
until grep -Fxq debug "$work/out/levels" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -le 30 ] || fail 'watched child did not start'
  sleep 1
done
kv app/config/log_level info
i=0
until grep -Fxq info "$work/out/levels" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -le 30 ] || fail "KV change did not restart the child: $(cat "$work/out/levels")"
  sleep 1
done
docker stop -t 20 "$watcher" >/dev/null
test "$(docker inspect -f '{{.State.ExitCode}}' "$watcher")" = 0 ||
  fail "watcher exited $(docker inspect -f '{{.State.ExitCode}}' "$watcher") after a forwarded TERM"
printf 'debug\nint\ninfo\nterm\n' >"$work/want"
cmp -s "$work/out/levels" "$work/want" || fail "unexpected child lifecycle: $(cat "$work/out/levels")"

# Vault: a token limited to one KV v2 secret supplies it as variables.
vault kv put secret/app password=s3cr3t >/dev/null || fail 'could not write the Vault secret'
printf 'path "secret/data/app" {\n  capabilities = ["read"]\n}\n' |
  docker exec -i -e VAULT_ADDR=http://127.0.0.1:8200 -e "VAULT_TOKEN=$vault_root" "$vault" \
    vault policy write app-read - >/dev/null || fail 'could not write the Vault policy'
app_token=$(vault token create -policy=app-read -field=token) || fail 'could not create a Vault token'
timeout 60 docker run --rm --label "$label" --network "$network" --read-only --cap-drop=ALL \
  -e "VAULT_TOKEN=$app_token" "$image" -vault-addr "http://$vault:8200" -secret secret/app \
  -pristine -once env >"$work/vault" 2>&1 || fail "Vault run failed: $(cat "$work/vault")"
grep -Fx secret_app_password=s3cr3t "$work/vault" >/dev/null ||
  fail "Vault secret is missing: $(cat "$work/vault")"

echo 'SMOKE PASS'
