#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
label=verity.test=nsc-$$
volume="verity-nsc-store-$$"
work=$(mktemp -d)

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -fv >/dev/null 2>&1 || true
  docker volume rm "$volume" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

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
  '["/usr/bin/nsc"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'CA bundle environment is missing'

docker run --rm --network none --read-only "$image" --version >"$work/version" 2>&1 ||
  fail "nsc --version failed: $(cat "$work/version")"
grep -Fx "nsc version ${expected_version}" "$work/version" >/dev/null ||
  fail "unexpected version output: $(cat "$work/version")"

if docker run --rm --network none --read-only "$image" --definitely-invalid \
  >"$work/invalid" 2>&1; then
  fail 'an unknown flag was accepted'
fi
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"

# The volume inherits /home/nonroot ownership from the image, so the non-root
# user can write its config, store and keys there while the root fs stays read-only.
docker volume create --label "$label" "$volume" >/dev/null

nsc() {
  docker run --rm --label "$label" --network none --read-only \
    -v "$volume:/home/nonroot" \
    -e NSC_HOME=/home/nonroot/config \
    -e NKEYS_PATH=/home/nonroot/keys \
    -e NSC_NO_GIT_IGNORE=1 \
    "$image" --data-dir /home/nonroot/stores "$@"
}

nsc add operator --name verity-op >"$work/operator" 2>&1 ||
  fail "add operator failed: $(cat "$work/operator")"
grep -F 'generated and stored operator key' "$work/operator" >/dev/null ||
  fail "operator key was not generated: $(cat "$work/operator")"
nsc add account --name verity-acct >"$work/account" 2>&1 ||
  fail "add account failed: $(cat "$work/account")"
grep -F 'added account "verity-acct"' "$work/account" >/dev/null ||
  fail "account was not added: $(cat "$work/account")"
nsc add user --account verity-acct --name alice --allow-pub 'orders.>' \
  >"$work/user" 2>&1 || fail "add user failed: $(cat "$work/user")"
grep -F 'added user "alice" to account "verity-acct"' "$work/user" >/dev/null ||
  fail "user was not added: $(cat "$work/user")"

nsc describe operator --json >"$work/operator.json" 2>"$work/err" ||
  fail "describe operator failed: $(cat "$work/err")"
nsc describe account --name verity-acct --json >"$work/account.json" 2>"$work/err" ||
  fail "describe account failed: $(cat "$work/err")"
nsc describe user --account verity-acct --name alice --json >"$work/user.json" 2>"$work/err" ||
  fail "describe user failed: $(cat "$work/err")"

json_field() {
  python3 -c 'import json,sys; v=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): v=v[k]
print(v if not isinstance(v, list) else ",".join(v))' "$1" "$2"
}

operator_id=$(json_field "$work/operator.json" sub)
account_id=$(json_field "$work/account.json" sub)
user_id=$(json_field "$work/user.json" sub)
printf '%s\n' "$operator_id" | grep -Ex 'O[A-Z2-7]{55}' >/dev/null ||
  fail "bad operator subject: $operator_id"
printf '%s\n' "$account_id" | grep -Ex 'A[A-Z2-7]{55}' >/dev/null ||
  fail "bad account subject: $account_id"
printf '%s\n' "$user_id" | grep -Ex 'U[A-Z2-7]{55}' >/dev/null ||
  fail "bad user subject: $user_id"
test "$(json_field "$work/operator.json" nats.type)" = operator || fail 'operator JWT type'
test "$(json_field "$work/account.json" iss)" = "$operator_id" ||
  fail 'account JWT is not issued by the operator'
test "$(json_field "$work/account.json" nats.type)" = account || fail 'account JWT type'
test "$(json_field "$work/user.json" name)" = alice || fail 'user JWT name'
test "$(json_field "$work/user.json" iss)" = "$account_id" ||
  fail 'user JWT is not issued by the account'
test "$(json_field "$work/user.json" nats.type)" = user || fail 'user JWT type'
test "$(json_field "$work/user.json" nats.pub.allow)" = 'orders.>' ||
  fail "user publish permission missing: $(cat "$work/user.json")"

# Write creds into the store volume, then copy them out through a stopped container.
nsc generate creds --account verity-acct --name alice \
  --output-file /home/nonroot/alice.creds >"$work/gen" 2>&1 ||
  fail "generate creds failed: $(cat "$work/gen")"
holder=$(docker create --label "$label" -v "$volume:/home/nonroot" "$image")
docker cp "$holder:/home/nonroot/alice.creds" "$work/alice.creds" >/dev/null ||
  fail 'creds file was not written'
creds=$work/alice.creds
for marker in '-----BEGIN NATS USER JWT-----' '------END NATS USER JWT------' \
  '-----BEGIN USER NKEY SEED-----' '------END USER NKEY SEED------'; do
  grep -Fx -- "$marker" "$creds" >/dev/null || fail "creds file is missing $marker"
done
seed=$(awk '/BEGIN USER NKEY SEED/ { getline; print; exit }' "$creds")
printf '%s\n' "$seed" | grep -Ex 'SU[A-Z2-7]{56}' >/dev/null ||
  fail 'creds file does not contain a user NKEY seed'
jwt=$(awk '/BEGIN NATS USER JWT/ { getline; print; exit }' "$creds")
payload=$(printf '%s' "$jwt" | cut -d. -f2 | python3 -c 'import base64,sys
s=sys.stdin.read().strip(); print(base64.urlsafe_b64decode(s + "=" * (-len(s) % 4)).decode())')
printf '%s' "$payload" | python3 -c 'import json,sys
c=json.load(sys.stdin); a=sys.argv
assert c["sub"] == a[1] and c["iss"] == a[2] and c["name"] == "alice", c' \
  "$user_id" "$account_id" || fail "creds JWT claims do not match the stored user: $payload"

# Creds can also be streamed to stdout and must carry the same identity.
nsc generate creds --account verity-acct --name alice >"$work/stdout.creds" 2>"$work/err" ||
  fail "generate creds to stdout failed: $(cat "$work/err")"
grep -Fx "$jwt" "$work/stdout.creds" >/dev/null || fail 'stdout creds JWT mismatch'
grep -Fx "$seed" "$work/stdout.creds" >/dev/null || fail 'stdout creds seed mismatch'

# Negative cases: unknown users and accounts must fail with a clear diagnostic.
if nsc describe user --account verity-acct --name mallory --json >"$work/neg" 2>&1; then
  fail 'describing a missing user succeeded'
fi
grep -F 'user mallory does not exist' "$work/neg" >/dev/null ||
  fail "missing user diagnostic: $(cat "$work/neg")"
if nsc generate creds --account no-such-acct --name alice >"$work/neg" 2>&1; then
  fail 'generating creds for a missing account succeeded'
fi
grep -F 'no-such-acct' "$work/neg" >/dev/null ||
  fail "missing account diagnostic: $(cat "$work/neg")"
grep -F 'BEGIN USER NKEY SEED' "$work/neg" >/dev/null &&
  fail 'a failed creds generation leaked a seed'

printf 'SMOKE PASS image=%s\n' "$image"
