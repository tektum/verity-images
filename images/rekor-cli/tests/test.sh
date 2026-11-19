#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }

# Helper indexes. The Trillian log server pin is the one upstream rekor's own
# Dockerfile.trillian-log-server uses; createdb is the sigstore scaffolding job
# that installs the Trillian MySQL schema; rekor-server is the upstream server
# release the candidate client talks to.
curl_index=docker.io/curlimages/curl:8.14.1@sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b
openssl_index=docker.io/alpine/openssl:3.5.9@sha256:c92fcbb1da06f6e22bf842833e4713df02a382116d8a40312546b599ec19ca30
mysql_index=docker.io/library/mysql:8.4@sha256:a81d043930e51745522bd5c430961cf8286f0a23f0a9a2a6e0108f7ea71b0902
createdb_index=ghcr.io/sigstore/scaffolding/createdb:v0.7.28@sha256:dbe82f82eaea1f1f13fd2d68bae85b76300587e56d9cce3de98f886d50fc2672
log_server_index=ghcr.io/sigstore/scaffolding/trillian_log_server:v1.8.0@sha256:13ca51c72694310c6d8d24de54a679fbab00e31764534ca8b7ed2a5004d5ef07
log_signer_index=ghcr.io/sigstore/scaffolding/trillian_log_signer:v1.8.0@sha256:7932dc61c586878d3d92bd6e14551e358a9d6dfc95f4ec5af2f49eea23d7d942
rekor_server_index=ghcr.io/sigstore/rekor/rekor-server:v1.6.2@sha256:e079a75490e2236f9e9dd9bc00768c04337ef6d7c1dcdbcc5c03733639847f98

suffix=$$
network="verity-rekor-cli-test-$suffix"
mysql="verity-rekor-cli-mysql-$suffix"
log_server="verity-rekor-cli-tlserver-$suffix"
log_signer="verity-rekor-cli-tlsigner-$suffix"
rekor="verity-rekor-cli-rekor-$suffix"
home="verity-rekor-cli-home-$suffix"
tmp=$(mktemp -d)
user=$(id -u):$(id -g)
db_password='rekor-test-only'
mysql_uri="trillian:$db_password@tcp(mysql:3306)"
server=http://rekor:3000

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$rekor" "$log_signer" "$log_server" "$mysql" >/dev/null 2>&1 || true
  docker volume rm "$home" >/dev/null 2>&1 || true
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
rekor_server_image=$(pull_child "$rekor_server_index") || exit 1

# OCI contract: upstream `deploy-cli` image entrypoint, no default arguments.
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/rekor-cli"]' ] ||
  fail "unexpected entrypoint: $(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")"
[ "$(docker image inspect -f '{{json .Config.Cmd}}' "$image")" = null ] ||
  fail "unexpected cmd: $(docker image inspect -f '{{json .Config.Cmd}}' "$image")"
[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] ||
  fail "unexpected user: $(docker image inspect -f '{{.Config.User}}' "$image")"

out=$(docker run --rm "$image" version 2>&1) || fail "version failed: $out"
printf '%s\n' "$out" | grep -Eq "^GitVersion: +v$expected_version(\+dirty)?\$" ||
  fail "version does not report v$expected_version: $out"
printf '%s\n' "$out" | grep -Eq '^GitCommit: +[0-9a-f]{40}$' ||
  fail "version does not report a source commit: $out"

out=$(docker run --rm "$image" --help 2>&1) || fail "--help failed: $out"
for command in upload verify get search loginfo logproof; do
  printf '%s\n' "$out" | grep -Eq "^  $command " || fail "--help lacks the $command command"
done

# Negative: an unreachable server is a hard error, not a silent success.
status=0
out=$(docker run --rm --network none "$image" loginfo --rekor_server http://127.0.0.1:1 --retry 0 2>&1) ||
  status=$?
[ "$status" -ne 0 ] || fail "loginfo against an unreachable server exited 0: $out"
printf '%s\n' "$out" | grep -Fq 'connection refused' ||
  fail "loginfo against an unreachable server did not report the dial failure: $out"

# Backends as in upstream docker-compose.yml: MySQL for Trillian storage and the
# search index, a Trillian log server, a log signer and the upstream server. The
# network is internal, so nothing in the test can reach external services.
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

docker run -d --name "$rekor" --network "$network" --network-alias rekor "$rekor_server_image" \
  serve --rekor_server.address=0.0.0.0 \
  --trillian_log_server.address=trillian-log-server --trillian_log_server.port=8090 \
  --search_index.storage_provider=mysql \
  --search_index.mysql.dsn="$mysql_uri/trillian?parseTime=true" >/dev/null

i=0
until out=$(curl_run -f "$server/ping" 2>&1) && [ "$out" = . ]; do
  i=$((i + 1))
  if [ "$i" -ge 90 ] || [ "$(docker inspect -f '{{.State.Running}}' "$rekor")" != true ]; then
    dump_logs "$rekor" "$log_server"
    fail "rekor /ping did not answer: $out"
  fi
  sleep 1
done
curl_run -f "$server/api/v1/log/publicKey" -o rekor.pub || fail 'GET publicKey failed'

# Signed artifact: throwaway P-256 key.
printf '%s\n' "verity rekor-cli smoke artifact $suffix" >"$tmp/artifact.txt"
printf '%s\n' 'a different artifact' >"$tmp/other.txt"
printf '%s\n' "verity rekor-cli second artifact $suffix" >"$tmp/second.txt"
openssl_run() {
  docker run --rm --network none --user "$user" -v "$tmp:/work" -w /work "$openssl_image" "$@"
}
openssl_run ecparam -name prime256v1 -genkey -noout -out key.pem || fail 'key generation failed'
openssl_run ec -in key.pem -pubout -out pub.pem 2>/dev/null || fail 'public key export failed'
openssl_run dgst -sha256 -sign key.pem -out artifact.sig artifact.txt || fail 'signing failed'
openssl_run dgst -sha256 -sign key.pem -out other.sig other.txt || fail 'signing failed'
openssl_run dgst -sha256 -sign key.pem -out second.sig second.txt || fail 'signing failed'
digest=$(sha256sum "$tmp/artifact.txt" | cut -d' ' -f1)

# CLI configs: one pinning the server's real public key, one pinning an
# unrelated key, which must make checkpoint verification fail.
pin_config() {
  { printf 'rekor_server_public_key: |\n'; sed 's/^/  /' "$tmp/$1"; } >"$tmp/$2"
}
pin_config rekor.pub pinned.yaml
pin_config pub.pem wrong-key.yaml
chmod 755 "$tmp"
chmod 644 "$tmp"/*

# The candidate runs as its image user with a persistent $HOME volume, which
# Docker seeds from the image's /home/nonroot, so tree state survives between
# invocations as it would for an interactive user.
docker volume create "$home" >/dev/null
cli() {
  docker run --rm --network "$network" -v "$tmp:/work:ro" -v "$home:/home/nonroot" "$image" \
    --rekor_server "$server" "$@"
}

out=$(cli loginfo 2>&1) || fail "loginfo on the empty log failed: $out"
printf '%s\n' "$out" | grep -Fxq 'Verification Successful!' || fail "loginfo did not verify: $out"
printf '%s\n' "$out" | grep -Eq '^Active Tree Size: +0$' || fail "fresh log is not empty: $out"
# Upstream never persists the checkpoint of an empty log.
printf '%s\n' "$out" | grep -Fq 'do not persist state for empty logs' ||
  fail "first loginfo did not skip storing the empty-log checkpoint: $out"

out=$(cli upload --type hashedrekord --pki-format x509 --artifact /work/artifact.txt \
  --signature /work/artifact.sig --public-key /work/pub.pem 2>&1) || fail "upload failed: $out"
printf '%s\n' "$out" | grep -Eq "^Created entry at index 0, available at: $server/api/v1/log/entries/[0-9a-f]+\$" ||
  fail "upload did not create entry 0: $out"
uuid=${out##*/}
# Entry IDs carry a 16-hex tree ID prefix ahead of the 64-hex leaf hash.
leaf=$(printf '%s' "$uuid" | tail -c 64)

# Negative: a duplicate upload reports the existing entry; a signature over
# other content is rejected by the server and surfaced as an error.
out=$(cli upload --type hashedrekord --pki-format x509 --artifact /work/artifact.txt \
  --signature /work/artifact.sig --public-key /work/pub.pem 2>&1) || fail "duplicate upload failed: $out"
printf '%s\n' "$out" | grep -Fq "Entry already exists; available at: $server/api/v1/log/entries/$uuid" ||
  fail "duplicate upload did not report the existing entry: $out"
status=0
out=$(cli upload --type hashedrekord --pki-format x509 --artifact /work/artifact.txt \
  --signature /work/other.sig --public-key /work/pub.pem 2>&1) || status=$?
[ "$status" -ne 0 ] || fail "upload with a mismatched signature succeeded: $out"

out=$(cli verify --type hashedrekord --pki-format x509 --artifact /work/artifact.txt \
  --signature /work/artifact.sig --public-key /work/pub.pem 2>&1) || fail "verify failed: $out"
printf '%s\n' "$out" | grep -Fxq 'Entry Index in Current Tree: 0' || fail "verify did not report entry 0: $out"
printf '%s\n' "$out" | grep -Fxq "Entry Hash: $leaf" || fail "verify did not report leaf $leaf: $out"
status=0
out=$(cli verify --type hashedrekord --pki-format x509 --artifact /work/other.txt \
  --signature /work/artifact.sig --public-key /work/pub.pem 2>&1) || status=$?
[ "$status" -ne 0 ] || fail "verify of a tampered artifact succeeded: $out"

out=$(cli get --log-index 0 --format json 2>&1) || fail "get failed: $out"
printf '%s\n' "$out" | jq -e --arg l "$leaf" --arg h "$digest" \
  '(.UUID | endswith($l)) and .LogIndex == 0 and .Body.HashedRekordObj.data.hash.value == $h' >/dev/null ||
  fail "get returned an unexpected entry: $out"

# The search index is written asynchronously after the entry is integrated.
i=0
until out=$(cli search --sha "sha256:$digest" 2>&1) && printf '%s\n' "$out" | grep -Eq "^([0-9a-f]{16})?$leaf\$"; do
  i=$((i + 1))
  [ "$i" -lt 20 ] || fail "search did not return $uuid: $out"
  sleep 1
done

# loginfo at size 1 stores the checkpoint in $HOME; after a second entry the
# next loginfo must prove consistency from it instead of starting over.
out=$(cli loginfo 2>&1) || fail "loginfo after upload failed: $out"
printf '%s\n' "$out" | grep -Eq '^Active Tree Size: +1$' || fail "log size is not 1: $out"
out=$(cli upload --type hashedrekord --pki-format x509 --artifact /work/second.txt \
  --signature /work/second.sig --public-key /work/pub.pem 2>&1) || fail "second upload failed: $out"
printf '%s\n' "$out" | grep -Fq 'Created entry at index 1,' || fail "second upload did not create entry 1: $out"
out=$(cli loginfo 2>&1) || fail "loginfo after the second upload failed: $out"
printf '%s\n' "$out" | grep -Eq '^Active Tree Size: +2$' || fail "log size is not 2: $out"
if printf '%s\n' "$out" | grep -Fq 'No previous log state stored'; then
  fail "loginfo did not prove consistency from the state stored in \$HOME: $out"
fi

out=$(cli --config /work/pinned.yaml loginfo --store_tree_state=false 2>&1) ||
  fail "loginfo with the pinned server key failed: $out"
printf '%s\n' "$out" | grep -Fxq 'Verification Successful!' || fail "pinned-key loginfo did not verify: $out"
status=0
out=$(cli --config /work/wrong-key.yaml loginfo --store_tree_state=false 2>&1) || status=$?
[ "$status" -ne 0 ] || fail "loginfo with a wrong pinned server key succeeded: $out"
printf '%s\n' "$out" | grep -Fq 'signature on tree head did not verify' ||
  fail "wrong-key loginfo did not report the checkpoint signature failure: $out"

printf 'SMOKE PASS image=%s\n' "$image"
