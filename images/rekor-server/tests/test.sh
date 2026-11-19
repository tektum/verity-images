#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }

# Helper indexes. The Trillian log server pin is the one upstream rekor's own
# Dockerfile.trillian-log-server uses; createdb is the sigstore scaffolding job
# that installs the Trillian MySQL schema; rekor-cli is the upstream client
# release used only as an independent verifier of this server's proofs.
curl_index=docker.io/curlimages/curl:8.14.1@sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b
openssl_index=docker.io/alpine/openssl:3.5.9@sha256:c92fcbb1da06f6e22bf842833e4713df02a382116d8a40312546b599ec19ca30
mysql_index=docker.io/library/mysql:8.4@sha256:a81d043930e51745522bd5c430961cf8286f0a23f0a9a2a6e0108f7ea71b0902
createdb_index=ghcr.io/sigstore/scaffolding/createdb:v0.7.28@sha256:dbe82f82eaea1f1f13fd2d68bae85b76300587e56d9cce3de98f886d50fc2672
log_server_index=ghcr.io/sigstore/scaffolding/trillian_log_server:v1.8.0@sha256:13ca51c72694310c6d8d24de54a679fbab00e31764534ca8b7ed2a5004d5ef07
log_signer_index=ghcr.io/sigstore/scaffolding/trillian_log_signer:v1.8.0@sha256:7932dc61c586878d3d92bd6e14551e358a9d6dfc95f4ec5af2f49eea23d7d942
rekor_cli_index=ghcr.io/sigstore/rekor/rekor-cli:v1.6.2@sha256:a9e27845662d582eafaedf0fe0410d2311cfb8e48870f6b4f14bf146ab930620

suffix=$$
network="verity-rekor-server-test-$suffix"
mysql="verity-rekor-server-mysql-$suffix"
log_server="verity-rekor-server-tlserver-$suffix"
log_signer="verity-rekor-server-tlsigner-$suffix"
rekor="verity-rekor-server-rekor-$suffix"
tmp=$(mktemp -d)
user=$(id -u):$(id -g)
db_password='rekor-test-only'
mysql_uri="trillian:$db_password@tcp(mysql:3306)"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$rekor" "$log_signer" "$log_server" "$mysql" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

dump_logs() {
  for c in "$@"; do
    printf '=== %s\n' "$c" >&2
    docker logs --tail 80 "$c" >&2 2>&1 || true
  done
}

# image_arch, pull_child: resolve each pinned helper index to the candidate's
# platform child, verifying the index bytes against the pin. A classic Docker
# store cannot bind one index digest to a second platform's image.
image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
pull_child() {
  raw=$(docker buildx imagetools inspect --raw "$1") || fail "cannot inspect $1"
  [ "sha256:$(printf '%s' "$raw" | sha256sum | cut -d' ' -f1)" = "${1#*@}" ] ||
    fail "index digest mismatch for $1"
  child=$(printf '%s' "$raw" | jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') || fail "cannot resolve a child of $1"
  case $child in
    sha256:*) ;;
    *) fail "no unique linux/$image_arch child in $1" ;;
  esac
  docker pull --quiet --platform "linux/$image_arch" "${1%%@*}@$child" >/dev/null ||
    fail "cannot pull ${1%%@*}@$child"
  printf '%s' "${1%%@*}@$child"
}
curl_image=$(pull_child "$curl_index") || exit 1
openssl_image=$(pull_child "$openssl_index") || exit 1
mysql_image=$(pull_child "$mysql_index") || exit 1
createdb_image=$(pull_child "$createdb_index") || exit 1
log_server_image=$(pull_child "$log_server_index") || exit 1
log_signer_image=$(pull_child "$log_signer_index") || exit 1
rekor_cli_image=$(pull_child "$rekor_cli_index") || exit 1

# OCI contract: upstream `deploy` image entrypoint and default command, with the
# listen address every upstream deployment passes baked in.
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/rekor-server"]' ] ||
  fail "unexpected entrypoint: $(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")"
[ "$(docker image inspect -f '{{json .Config.Cmd}}' "$image")" = '["serve","--rekor_server.address=0.0.0.0"]' ] ||
  fail "unexpected cmd: $(docker image inspect -f '{{json .Config.Cmd}}' "$image")"
[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] ||
  fail "unexpected user: $(docker image inspect -f '{{.Config.User}}' "$image")"

out=$(docker run --rm "$image" version 2>&1) || fail "version failed: $out"
printf '%s\n' "$out" | grep -Eq "^GitVersion: +v$expected_version(\+dirty)?\$" ||
  fail "version does not report v$expected_version: $out"
printf '%s\n' "$out" | grep -Eq '^GitCommit: +[0-9a-f]{40}$' ||
  fail "version does not report a source commit: $out"

out=$(docker run --rm "$image" serve --help 2>&1) || fail "serve --help failed: $out"
for flag in --trillian_log_server.address --search_index.storage_provider --rekor_server.signer; do
  printf '%s\n' "$out" | grep -Fq -- "$flag" || fail "serve --help lacks $flag"
done

# Negative: without a reachable Trillian log server, `serve` must fail fast at
# tree creation instead of listening without a backend.
status=0
out=$(timeout 120 docker run --rm --network none "$image" 2>&1) || status=$?
[ "$status" -ne 0 ] || fail 'serve without Trillian exited 0'
[ "$status" -ne 124 ] || fail 'serve without Trillian did not exit within 120s'
printf '%s\n' "$out" | grep -Fq 'create and init tree: create tree: rpc error: code = Unavailable' ||
  { printf '%s\n' "$out" | tail -20 >&2; fail 'serve without Trillian did not report the Trillian dial failure'; }

# Backends as in upstream docker-compose.yml: MySQL for Trillian storage and the
# search index, a Trillian log server and a log signer. The network is internal,
# so nothing in the test can reach external services.
docker network create --internal "$network" >/dev/null

docker run -d --name "$mysql" --network "$network" --network-alias mysql \
  -e MYSQL_ROOT_PASSWORD=root -e MYSQL_DATABASE=trillian -e MYSQL_USER=trillian \
  -e MYSQL_PASSWORD="$db_password" "$mysql_image" >/dev/null
# The entrypoint's init server runs with networking disabled, so only a TCP
# login as the application user proves the final server is up.
i=0
until docker exec "$mysql" mysql -h 127.0.0.1 -u trillian -p"$db_password" -e 'SELECT 1' trillian >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 180 ] || { dump_logs "$mysql"; fail 'MySQL did not become ready'; }
  sleep 1
done

docker run --rm --network "$network" "$createdb_image" \
  --mysql_uri="$mysql_uri" --db_name=trillian >"$tmp/createdb.log" 2>&1 ||
  { cat "$tmp/createdb.log" >&2; fail 'Trillian schema creation failed'; }
tables=$(docker exec "$mysql" mysql -N -h 127.0.0.1 -u trillian -p"$db_password" -e 'SHOW TABLES' trillian 2>/dev/null)
printf '%s\n' "$tables" | grep -Fxq Trees || fail "Trillian schema missing Trees: $tables"

trillian_args="--quota_system=noop --storage_system=mysql --mysql_uri=$mysql_uri/trillian?parseTime=true --rpc_endpoint=0.0.0.0:8090 --http_endpoint=0.0.0.0:8091 --alsologtostderr"
# shellcheck disable=SC2086
docker run -d --name "$log_server" --network "$network" --network-alias trillian-log-server \
  "$log_server_image" $trillian_args >/dev/null
# shellcheck disable=SC2086
docker run -d --name "$log_signer" --network "$network" \
  "$log_signer_image" $trillian_args --force_master >/dev/null

curl_run() {
  docker run --rm --network "$network" --user "$user" -v "$tmp:/work" -w /work "$curl_image" \
    -sS --max-time 30 "$@"
}

i=0
until out=$(curl_run -f "http://trillian-log-server:8091/healthz" 2>&1); do
  i=$((i + 1))
  [ "$i" -lt 60 ] || { dump_logs "$log_server"; fail "Trillian log server not healthy: $out"; }
  sleep 1
done

# The candidate, with the image's own default listen address, a read-only root
# filesystem, and MySQL as the search index. No tree ID: the server creates and
# initializes its own tree, which exercises the Trillian admin API end to end.
docker run -d --name "$rekor" --network "$network" --network-alias rekor --read-only "$image" \
  serve --rekor_server.address=0.0.0.0 \
  --trillian_log_server.address=trillian-log-server --trillian_log_server.port=8090 \
  --search_index.storage_provider=mysql \
  --search_index.mysql.dsn="$mysql_uri/trillian?parseTime=true" >/dev/null

# /ping is the go-openapi Heartbeat middleware: HTTP 200 with body ".".
i=0
until out=$(curl_run -f "http://rekor:3000/ping" 2>&1) && [ "$out" = . ]; do
  i=$((i + 1))
  if [ "$i" -ge 90 ] || [ "$(docker inspect -f '{{.State.Running}}' "$rekor")" != true ]; then
    dump_logs "$rekor" "$log_server"
    fail "rekor /ping did not answer: $out"
  fi
  sleep 1
done
[ "$(docker top "$rekor" -o pid,uid | awk 'NR == 2 { print $2 }')" = 65532 ] ||
  fail 'server is not running as uid 65532'

curl_run -f "http://rekor:3000/api/v1/log" -o loginfo0.json || fail 'GET /api/v1/log failed'
[ "$(jq -r .treeSize "$tmp/loginfo0.json")" = 0 ] || fail "fresh log is not empty: $(cat "$tmp/loginfo0.json")"
tree_id=$(jq -r .treeID "$tmp/loginfo0.json")
case $tree_id in
  '' | null | 0) fail "log info has no tree ID: $(cat "$tmp/loginfo0.json")" ;;
esac
curl_run -f "http://rekor:3000/api/v1/log/publicKey" -o rekor.pub || fail 'GET publicKey failed'
grep -Fq -- '-----BEGIN PUBLIC KEY-----' "$tmp/rekor.pub" || fail 'publicKey is not a PEM public key'

# Signed artifact: throwaway P-256 key, hashedrekord entry built from it.
printf '%s\n' "verity rekor-server smoke artifact $suffix" >"$tmp/artifact.txt"
printf '%s\n' 'a different artifact' >"$tmp/other.txt"
chmod 755 "$tmp"
openssl_run() {
  docker run --rm --network none --user "$user" -v "$tmp:/work" -w /work "$openssl_image" "$@"
}
openssl_run ecparam -name prime256v1 -genkey -noout -out key.pem || fail 'key generation failed'
openssl_run ec -in key.pem -pubout -out pub.pem 2>/dev/null || fail 'public key export failed'
openssl_run dgst -sha256 -sign key.pem -out artifact.sig artifact.txt || fail 'signing failed'
openssl_run dgst -sha256 -sign key.pem -out other.sig other.txt || fail 'signing failed'
chmod 644 "$tmp"/*
digest=$(sha256sum "$tmp/artifact.txt" | cut -d' ' -f1)

entry() {
  jq -n --arg sig "$(base64 <"$tmp/$1" | tr -d '\n')" --arg key "$(base64 <"$tmp/pub.pem" | tr -d '\n')" \
    --arg hash "$2" '{apiVersion: "0.0.1", kind: "hashedrekord", spec: {
      signature: {content: $sig, publicKey: {content: $key}},
      data: {hash: {algorithm: "sha256", value: $hash}}}}'
}
entry artifact.sig "$digest" >"$tmp/entry.json"
entry other.sig "$digest" >"$tmp/bad-entry.json"

post_entry() {
  curl_run -o "$2" -w '%{http_code}' -H 'Content-Type: application/json' \
    --data-binary "@$1" "http://rekor:3000/api/v1/log/entries"
}

status=$(post_entry entry.json created.json) || fail 'POST entry failed'
[ "$status" = 201 ] || { dump_logs "$rekor"; fail "POST entry returned HTTP $status: $(cat "$tmp/created.json")"; }
uuid=$(jq -r 'keys[0]' "$tmp/created.json")
[ "$(jq -r '.[].logIndex' "$tmp/created.json")" = 0 ] || fail 'first entry is not logIndex 0'
jq -e '.[].verification.signedEntryTimestamp | length > 0' "$tmp/created.json" >/dev/null ||
  fail 'entry has no signed entry timestamp'
jq -e '.[].verification.inclusionProof.treeSize >= 1' "$tmp/created.json" >/dev/null ||
  fail 'entry has no inclusion proof'
jq -r '.[].body' "$tmp/created.json" | base64 -d | jq -e --arg h "$digest" \
  '.kind == "hashedrekord" and .spec.data.hash.value == $h' >/dev/null ||
  fail 'stored entry body does not carry the artifact hash'

# Negative: a duplicate entry is a conflict, and a signature over other content
# is rejected before it reaches the log.
status=$(post_entry entry.json dup.json) || fail 'duplicate POST failed'
[ "$status" = 409 ] || fail "duplicate entry returned HTTP $status, want 409"
status=$(post_entry bad-entry.json bad.json) || fail 'bad-signature POST failed'
[ "$status" = 400 ] || fail "bad signature returned HTTP $status, want 400: $(cat "$tmp/bad.json")"

curl_run -f "http://rekor:3000/api/v1/log/entries/$uuid" -o got.json || fail 'GET entry by UUID failed'
[ "$(jq -r '.[].body' "$tmp/got.json")" = "$(jq -r '.[].body' "$tmp/created.json")" ] ||
  fail 'GET entry by UUID returned a different body'

# The MySQL search index resolves the artifact hash to the entry. Index writes
# are asynchronous, so allow a short settle time.
i=0
until found=$(curl_run -f -H 'Content-Type: application/json' \
  --data "{\"hash\":\"sha256:$digest\"}" "http://rekor:3000/api/v1/index/retrieve") &&
  printf '%s' "$found" | jq -e --arg u "$uuid" 'index($u) != null' >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 20 ] || fail "search index did not return $uuid: $found"
  sleep 1
done

curl_run -f "http://rekor:3000/api/v1/log" -o loginfo1.json || fail 'GET /api/v1/log failed'
[ "$(jq -r .treeSize "$tmp/loginfo1.json")" = 1 ] || fail "log size is not 1: $(cat "$tmp/loginfo1.json")"
[ "$(jq -r .treeID "$tmp/loginfo1.json")" = "$tree_id" ] || fail 'active tree changed'

curl_run -f "http://rekor:2112/metrics" -o metrics.txt || fail 'metrics endpoint on :2112 did not answer'
grep -Eq '^rekor_new_entries 1$' "$tmp/metrics.txt" || fail 'rekor_new_entries is not 1'

# Independent verification with the upstream client: inclusion proof, signed
# checkpoint and signed entry timestamp against this server's public key.
cli_run() {
  docker run --rm --network "$network" -v "$tmp:/work:ro" "$rekor_cli_image" "$@"
}
out=$(cli_run verify --rekor_server http://rekor:3000 --type hashedrekord --pki-format x509 \
  --artifact /work/artifact.txt --signature /work/artifact.sig --public-key /work/pub.pem 2>&1) ||
  fail "upstream rekor-cli verify failed: $out"
printf '%s\n' "$out" | grep -Fxq 'Entry Index in Current Tree: 0' || fail "verify did not report entry 0: $out"
status=0
out=$(cli_run verify --rekor_server http://rekor:3000 --type hashedrekord --pki-format x509 \
  --artifact /work/other.txt --signature /work/artifact.sig --public-key /work/pub.pem 2>&1) || status=$?
[ "$status" -ne 0 ] || fail "verify of a tampered artifact succeeded: $out"

printf 'SMOKE PASS image=%s\n' "$image"
