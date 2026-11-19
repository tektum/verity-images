#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }

curl_image=docker.io/curlimages/curl:8.14.1@sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b
openssl_image=docker.io/alpine/openssl:3.5.9@sha256:c92fcbb1da06f6e22bf842833e4713df02a382116d8a40312546b599ec19ca30

suffix=$$
network="verity-tsa-test-$suffix"
memory="verity-tsa-memory-$suffix"
file="verity-tsa-file-$suffix"
negative="verity-tsa-negative-$suffix"
tmp=$(mktemp -d)
user=$(id -u):$(id -g)

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$memory" "$file" "$negative" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

# Internal network: no route out, so NTP monitoring can only log errors and the
# test never depends on external services.
docker network create --internal "$network" >/dev/null

openssl_run() {
  docker run --rm --network none --user "$user" -v "$tmp:/work" -w /work "$openssl_image" "$@"
}

curl_run() {
  docker run --rm --network "$network" --user "$user" -v "$tmp:/work" -w /work "$curl_image" \
    -sS --max-time 10 "$@"
}

# /ping is the chi Heartbeat middleware: HTTP 200 with body ".".
wait_ready() {
  i=0
  until [ "$(curl_run -f "http://$1:3000/ping" 2>/dev/null)" = . ]; do
    i=$((i + 1))
    if [ "$i" -ge 60 ] || [ "$(docker inspect -f '{{.State.Running}}' "$1")" != true ]; then
      docker logs "$1" >&2 || true
      fail "$1: /ping did not answer"
    fi
    sleep 1
  done
}

# Run the image with ARGS (and an optional read-only bind MOUNT) and require it
# to exit non-zero at startup with WANT in its output.
expect_startup_failure() {
  want=$1
  mount=$2
  shift 2
  if [ -n "$mount" ]; then
    docker run -d --name "$negative" --network none -v "$mount" "$image" "$@" >/dev/null
  else
    docker run -d --name "$negative" --network none "$image" "$@" >/dev/null
  fi
  code=$(timeout 60 docker wait "$negative") || fail "server did not exit with: $*"
  out=$(docker logs "$negative" 2>&1)
  docker rm -f "$negative" >/dev/null
  [ "$code" != 0 ] || fail "server exited 0 with: $*"
  printf '%s\n' "$out" | grep -F "$want" >/dev/null || fail "startup failure lacks '$want': $out"
}

# Request a timestamp for $2 (an artifact in $tmp) from server $1, fetch the
# chain, and verify the reply offline. Files are prefixed with $1.
timestamp() {
  server=$1
  artifact=$2
  digest=$(sha256sum "$tmp/$artifact" | cut -d' ' -f1)
  openssl_run ts -query -digest "$digest" -sha256 -cert -out "$server.tsq" \
    || fail "$server: openssl ts -query failed"
  status=$(curl_run -o "$server.tsr" -w '%{http_code}' \
    -H 'Content-Type: application/timestamp-query' --data-binary "@$server.tsq" \
    "http://$server:3000/api/v1/timestamp") || fail "$server: timestamp request failed"
  [ "$status" = 200 ] || fail "$server: timestamp request returned HTTP $status, want 200"
  status=$(curl_run -o "$server-chain.pem" -w '%{http_code}' \
    "http://$server:3000/api/v1/timestamp/certchain") || fail "$server: certchain request failed"
  [ "$status" = 200 ] || fail "$server: certchain request returned HTTP $status"
  [ "$(grep -c 'BEGIN CERTIFICATE' "$tmp/$server-chain.pem")" -ge 2 ] \
    || fail "$server: certchain does not hold a leaf and a root"
  # Trust only the last certificate of the chain (the root).
  awk '/BEGIN CERTIFICATE/ { n++; buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }' \
    "$tmp/$server-chain.pem" >"$tmp/$server-root.pem"

  reply=$(openssl_run ts -reply -in "$server.tsr" -text 2>&1) || fail "$server: unreadable reply: $reply"
  printf '%s\n' "$reply" | grep -Fx 'Status: Granted.' >/dev/null || fail "$server: reply not granted: $reply"
  printf '%s\n' "$reply" | grep -F 'Hash Algorithm: sha256' >/dev/null || fail "$server: reply hash is not sha256"
  out=$(openssl_run ts -verify -queryfile "$server.tsq" -in "$server.tsr" \
    -CAfile "$server-root.pem" -untrusted "$server-chain.pem" 2>&1) \
    || fail "$server: reply does not verify against the query: $out"
  out=$(openssl_run ts -verify -data "$artifact" -in "$server.tsr" \
    -CAfile "$server-root.pem" -untrusted "$server-chain.pem" 2>&1) \
    || fail "$server: reply does not verify against the artifact: $out"
  printf '%s\n' "$out" | grep -Fx 'Verification: OK' >/dev/null || fail "$server: unexpected verify output: $out"
  # Negative: a different artifact must not verify.
  if openssl_run ts -verify -data other.txt -in "$server.tsr" \
    -CAfile "$server-root.pem" -untrusted "$server-chain.pem" >/dev/null 2>&1; then
    fail "$server: reply verified against a different artifact"
  fi
}

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/timestamp-server"]' ] \
  || fail 'unexpected entrypoint'
[ "$(docker image inspect -f '{{json .Config.Cmd}}' "$image")" = '["serve","--host=0.0.0.0","--port=3000"]' ] \
  || fail 'unexpected image command'

version_output=$(docker run --rm --network none "$image" version 2>&1) || fail 'timestamp-server version failed'
printf '%s\n' "$version_output" | grep -Ex "GitVersion: +v$expected_version(\+dirty)?" >/dev/null \
  || fail "unexpected version output: $version_output"

# Negative: an unknown signer must be rejected at startup.
expect_startup_failure 'unsupported signer type: bogus' '' serve --timestamp-signer=bogus

printf '%s\n' 'verity timestamp-authority smoke test artifact' >"$tmp/artifact.txt"
printf '%s\n' 'a different artifact' >"$tmp/other.txt"

# Default command and default (in-memory) signer.
docker run -d --name "$memory" --network "$network" "$image" >/dev/null
wait_ready "$memory"
[ "$(docker top "$memory" -o pid,uid | awk 'NR == 2 { print $2 }')" = 65532 ] \
  || fail 'server is not running as uid 65532'
curl_run "http://$memory:2112/metrics" | grep -F 'go_goroutines' >/dev/null \
  || fail 'metrics endpoint on :2112 did not answer'
timestamp "$memory" artifact.txt

# Negative: a malformed RFC 3161 request is rejected.
printf 'not a timestamp query' >"$tmp/bad.tsq"
status=$(curl_run -o /dev/null -w '%{http_code}' -H 'Content-Type: application/timestamp-query' \
  --data-binary @bad.tsq "http://$memory:3000/api/v1/timestamp") || fail 'malformed request failed'
[ "$status" = 400 ] || fail "malformed request returned HTTP $status, want 400"

# File signer with a throwaway root CA and TSA leaf generated for this run.
mkdir "$tmp/keys"
cat >"$tmp/keys/leaf.cnf" <<'EOF'
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, timeStamping
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
EOF
openssl_run ecparam -name prime256v1 -genkey -noout -out keys/root.key || fail 'root key generation failed'
openssl_run req -new -x509 -key keys/root.key -subj '/CN=verity test TSA root' -days 1 \
  -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' \
  -out keys/root.pem || fail 'root certificate generation failed'
openssl_run ecparam -name prime256v1 -genkey -noout -out keys/tsa.key || fail 'TSA key generation failed'
openssl_run req -new -key keys/tsa.key -subj '/CN=verity test TSA' -out keys/tsa.csr \
  || fail 'TSA CSR generation failed'
openssl_run x509 -req -in keys/tsa.csr -CA keys/root.pem -CAkey keys/root.key -CAcreateserial \
  -days 1 -extfile keys/leaf.cnf -out keys/tsa.pem || fail 'TSA certificate generation failed'
cat "$tmp/keys/tsa.pem" "$tmp/keys/root.pem" >"$tmp/keys/chain.pem"
# The server runs as uid 65532; the throwaway keys only have to be readable by it.
chmod 755 "$tmp/keys"
chmod 644 "$tmp/keys/tsa.key" "$tmp/keys/root.key" "$tmp/keys/chain.pem"

docker run -d --name "$file" --network "$network" -v "$tmp/keys:/keys:ro" "$image" \
  serve --host=0.0.0.0 --port=3000 --timestamp-signer=file \
  --file-signer-key-path=/keys/tsa.key --certificate-chain-path=/keys/chain.pem >/dev/null
wait_ready "$file"
timestamp "$file" artifact.txt
cmp -s "$tmp/$file-root.pem" "$tmp/keys/root.pem" \
  || fail 'file signer certchain does not end in the generated root'
openssl_run ts -reply -in "$file.tsr" -token_out -out "$file.token" || fail 'token extraction failed'
openssl_run pkcs7 -inform DER -in "$file.token" -print_certs -noout 2>&1 \
  | grep -Fx 'subject=CN=verity test TSA' >/dev/null \
  || fail 'file signer reply does not carry the generated TSA leaf'

# Negative: each reply must not verify against the other signer's root.
if openssl_run ts -verify -data artifact.txt -in "$memory.tsr" -CAfile keys/root.pem >/dev/null 2>&1; then
  fail 'memory signer reply verified against the file signer root'
fi
if openssl_run ts -verify -data artifact.txt -in "$file.tsr" \
  -CAfile "$memory-root.pem" -untrusted "$memory-chain.pem" >/dev/null 2>&1; then
  fail 'file signer reply verified against the memory signer root'
fi

# Negative: a chain whose leaf does not certify the signing key is rejected at
# startup.
expect_startup_failure 'public keys are not equal' "$tmp/keys:/keys:ro" \
  serve --timestamp-signer=file --file-signer-key-path=/keys/root.key \
  --certificate-chain-path=/keys/chain.pem

printf 'SMOKE PASS image=%s\n' "$image"
