#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
recipe="$(dirname "$0")/../melange.yaml"
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' "$recipe")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
source_commit=$(sed -n 's/^[[:space:]]*source-commit: \([0-9a-f]\{40\}\)$/\1/p' "$recipe")
[ -n "$source_commit" ] || { printf 'source commit not found\n' >&2; exit 1; }
short_commit=$(printf '%s' "$source_commit" | cut -c1-8)
# curl with libssh2 is the SFTP client; it is pinned by index digest.
curl_index='docker.io/curlimages/curl:8.23.0@sha256:3fb7e13e5d179a845c97d78204f3f1064d1907037f26a3ebf91710571151fd93'
suffix=$$
server="verity-sftpgo-$suffix"
network="verity-sftpgo-net-$suffix"
data_volume="verity-sftpgo-data-$suffix"
state_volume="verity-sftpgo-state-$suffix"
tmp=$(mktemp -d)

cleanup() {
  docker rm -f "$server" >/dev/null 2>&1 || true
  docker volume rm "$data_volume" "$state_volume" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  if docker inspect "$server" >/dev/null 2>&1; then
    docker logs --tail 50 "$server" >&2 || true
  fi
  exit 1
}

# Test-only random secrets; nothing here is a real credential.
random_secret() {
  od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
}

inspect() {
  docker image inspect "$image" --format "$1"
}

# OCI contract, identical to the upstream drakkan/sftpgo image.
[ "$(inspect '{{.Config.User}}')" = 1000:1000 ] ||
  fail "image user is $(inspect '{{.Config.User}}'), want 1000:1000"
[ "$(inspect '{{json .Config.Entrypoint}}')" = null ] ||
  fail "unexpected entrypoint: $(inspect '{{json .Config.Entrypoint}}')"
[ "$(inspect '{{json .Config.Cmd}}')" = '["sftpgo","serve"]' ] ||
  fail "unexpected cmd: $(inspect '{{json .Config.Cmd}}')"
[ "$(inspect '{{.Config.WorkingDir}}')" = /var/lib/sftpgo ] ||
  fail "unexpected working directory: $(inspect '{{.Config.WorkingDir}}')"
inspect '{{json .Config.Env}}' | grep -F '"SFTPGO_LOG_FILE_PATH="' >/dev/null ||
  fail 'SFTPGO_LOG_FILE_PATH is not set to an empty value'

# Version stamp: upstream version, 8-character commit, and build date, with
# the default upstream feature set including the cgo SQLite provider.
version=$(docker run --rm --network none "$image" sftpgo --version) ||
  fail 'sftpgo --version exited non-zero'
printf '%s\n' "$version" |
  grep -E "^SFTPGo ${expected_version}-${short_commit}-[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z " >/dev/null ||
  fail "unexpected version: $version"
for feature in +sqlite +bolt +mysql +pgsql +s3 +gcs +azblob +unixcrypt; do
  case " $version " in
    *" $feature "*) ;;
    *) fail "version does not report $feature: $version" ;;
  esac
done
printf 'VERSION %s\n' "$version"
# Upstream installs the binary in /usr/local/bin.
compat=$(docker run --rm --network none "$image" /usr/local/bin/sftpgo --version) ||
  fail '/usr/local/bin/sftpgo --version exited non-zero'
[ "$compat" = "$version" ] || fail "/usr/local/bin/sftpgo reports $compat"

# Account and packaged files.
probe=$(docker create "$image")
docker cp "$probe:/etc/passwd" "$tmp/passwd" >/dev/null
docker cp "$probe:/etc/sftpgo/sftpgo.json" "$tmp/sftpgo.json" >/dev/null
docker cp "$probe:/usr/share/sftpgo/openapi/openapi.yaml" "$tmp/openapi.yaml" >/dev/null
docker rm "$probe" >/dev/null
awk -F: '$1 == "sftpgo" && $3 == 1000 && $4 == 1000 && $6 == "/var/lib/sftpgo" && $7 == "/usr/sbin/nologin" { found = 1 } END { exit !found }' \
  "$tmp/passwd" || fail 'sftpgo account is not UID/GID 1000 with home /var/lib/sftpgo'
jq -e '.data_provider.driver == "sqlite" and .data_provider.users_base_dir == "/srv/sftpgo/data"
  and .data_provider.backups_path == "/srv/sftpgo/backups"
  and .sftpd.bindings[0].port == 2022 and .httpd.bindings[0].port == 8080' \
  "$tmp/sftpgo.json" >/dev/null || fail 'unexpected default /etc/sftpgo/sftpgo.json'

# Resolve the helper's per-platform child digest after verifying the index
# bytes against the pinned digest, so a classic image store can pull it.
image_arch=$(inspect '{{.Architecture}}')
curl_raw=$(docker buildx imagetools inspect --raw "$curl_index") ||
  fail 'cannot inspect curl helper index'
[ "sha256:$(printf '%s' "$curl_raw" | sha256sum | cut -d' ' -f1)" = "${curl_index#*@}" ] ||
  fail 'curl helper index digest mismatch'
curl_digest=$(printf '%s' "$curl_raw" |
  jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') ||
  fail 'cannot resolve curl helper digest'
case $curl_digest in
  sha256:*) ;;
  *) fail "no unique linux/$image_arch curl helper in $curl_index" ;;
esac
curl_image=docker.io/curlimages/curl@$curl_digest
docker pull --quiet --platform "linux/$image_arch" "$curl_image" >/dev/null ||
  fail 'cannot pull curl helper'

admin_password=$(random_secret)
user_password=$(random_secret)
wrong_password=$(random_secret)
chmod 0777 "$tmp"

docker network create "$network" >/dev/null
docker volume create "$data_volume" >/dev/null
docker volume create "$state_volume" >/dev/null

start_server() {
  docker run -d --name "$server" --network "$network" --network-alias sftpgo \
    -p 127.0.0.1::8080 \
    -v "$data_volume:/srv/sftpgo" -v "$state_volume:/var/lib/sftpgo" \
    "$@" "$image" >/dev/null || fail 'cannot start sftpgo'
  port=$(docker port "$server" 8080/tcp | awk -F: 'NR == 1 { print $NF }')
  [ -n "$port" ] || fail 'HTTP port 8080 is not published'
  base="http://127.0.0.1:$port"
  attempts=0
  until health=$(curl --fail --silent --max-time 5 "$base/healthz") && [ "$health" = ok ]; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 60 ] || fail '/healthz never returned ok'
    [ "$(docker inspect -f '{{.State.Running}}' "$server")" = true ] ||
      fail 'sftpgo exited before readiness'
    sleep 1
  done
  printf 'HEALTHZ %s/healthz -> %s\n' "$base" "$health"
}

# The default admin is created from the environment at first start.
start_server \
  -e SFTPGO_DATA_PROVIDER__CREATE_DEFAULT_ADMIN=true \
  -e SFTPGO_DEFAULT_ADMIN_USERNAME=admin \
  -e SFTPGO_DEFAULT_ADMIN_PASSWORD="$admin_password"

# Logs go to stdout because SFTPGO_LOG_FILE_PATH is empty.
docker logs "$server" 2>&1 | grep -F '"sender":"sftpd"' >/dev/null ||
  fail 'SFTP service did not log to stdout'

# The web UI and OpenAPI document are served from /usr/share/sftpgo.
curl --fail --silent --max-time 10 "$base/web/admin/login" | grep -F '<form' >/dev/null ||
  fail 'web admin login page did not render'
curl --fail --silent --max-time 10 "$base/openapi/openapi.yaml" >"$tmp/served-openapi.yaml" ||
  fail 'OpenAPI document is not served'
cmp -s "$tmp/served-openapi.yaml" "$tmp/openapi.yaml" ||
  fail 'served OpenAPI document differs from /usr/share/sftpgo/openapi/openapi.yaml'

# Negative: the REST API rejects a wrong admin password.
status=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 10 \
  --user "admin:$wrong_password" "$base/api/v2/token")
[ "$status" = 401 ] || fail "wrong admin password returned HTTP $status, want 401"

token=$(curl --fail --silent --max-time 10 --user "admin:$admin_password" \
  "$base/api/v2/token" | jq -er '.access_token') || fail 'cannot get an admin API token'

jq -n --arg password "$user_password" \
  '{username: "smoke", password: $password, status: 1, permissions: {"/": ["*"]}}' \
  >"$tmp/user.json"
curl --fail --silent --max-time 10 -H "Authorization: Bearer $token" \
  -H 'Content-Type: application/json' --data @"$tmp/user.json" \
  "$base/api/v2/users" >"$tmp/created.json" || fail 'cannot create SFTP user'
jq -e '.username == "smoke" and .home_dir == "/srv/sftpgo/data/smoke"' "$tmp/created.json" >/dev/null ||
  fail "unexpected created user: $(cat "$tmp/created.json")"

# Pin the server host key instead of skipping verification. The server
# generates RSA, ECDSA, and Ed25519 keys; the pinned libssh2 client prefers
# ECDSA, so the ECDSA key must be the one presented.
docker cp "$server:/var/lib/sftpgo/id_ecdsa.pub" "$tmp/host.pub" >/dev/null ||
  fail 'server did not generate an ECDSA host key in /var/lib/sftpgo'
host_sha256=$(awk '{ print $2 }' "$tmp/host.pub" | base64 -d | openssl dgst -sha256 -binary | base64 | tr -d '=')

sftp() {
  docker run --rm --network "$network" --user "$(id -u):$(id -g)" -v "$tmp:/work" \
    "$curl_image" --silent --show-error --hostpubsha256 "$host_sha256" \
    --connect-timeout 10 --max-time 60 "$@"
}

head -c 1048576 /dev/urandom >"$tmp/upload.bin"
upload_sha=$(sha256sum "$tmp/upload.bin" | cut -d' ' -f1)
sftp --user "smoke:$user_password" --upload-file /work/upload.bin \
  sftp://sftpgo:2022/upload.bin || fail 'SFTP upload failed'
printf 'SFTP UPLOAD sftp://sftpgo:2022/upload.bin bytes=%s sha256=%s\n' \
  "$(wc -c <"$tmp/upload.bin" | tr -d ' ')" "$upload_sha"

sftp --user "smoke:$user_password" --output /work/download.bin \
  sftp://sftpgo:2022/upload.bin || fail 'SFTP download failed'
download_sha=$(sha256sum "$tmp/download.bin" | cut -d' ' -f1)
printf 'SFTP DOWNLOAD sftp://sftpgo:2022/upload.bin bytes=%s sha256=%s\n' \
  "$(wc -c <"$tmp/download.bin" | tr -d ' ')" "$download_sha"
[ "$download_sha" = "$upload_sha" ] ||
  fail "downloaded sha256 $download_sha differs from uploaded $upload_sha"

# The upload landed in the user's home under /srv/sftpgo/data.
docker cp "$server:/srv/sftpgo/data/smoke/upload.bin" "$tmp/stored.bin" >/dev/null ||
  fail 'upload is not stored in /srv/sftpgo/data/smoke'
[ "$(sha256sum "$tmp/stored.bin" | cut -d' ' -f1)" = "$upload_sha" ] ||
  fail 'stored file differs from the upload'

# Negative: a wrong password is rejected over SFTP (curl 67, login denied).
set +e
sftp --user "smoke:$wrong_password" --output /work/denied.bin \
  sftp://sftpgo:2022/upload.bin 2>"$tmp/denied.err"
status=$?
set -e
[ "$status" -eq 67 ] || fail "wrong SFTP password exited $status, want 67 (login denied)"
[ ! -s "$tmp/denied.bin" ] || fail 'wrong SFTP password downloaded data'
printf 'SFTP WRONG PASSWORD rejected: curl exit %s: %s\n' "$status" "$(tr -d '\r\n' <"$tmp/denied.err")"

# +unixcrypt: a pre-hashed yescrypt password, as imported from /etc/shadow,
# authenticates through libcrypt. Public test fixture, not a credential.
yescrypt_password=a18f41b03d3daa1aee08b64a
# shellcheck disable=SC2016 # literal crypt(3) hash, not an expansion
yescrypt_hash='$y$j9T$830e574ef8088fb232c471$dyNX8KEsjocbI.gg7DeNjmUhE/4fkm9lO0nVnVsx8Y4'
jq -n --arg password "$yescrypt_hash" \
  '{username: "yescrypt", password: $password, status: 1, permissions: {"/": ["*"]}}' \
  >"$tmp/yescrypt.json"
curl --fail --silent --max-time 10 -H "Authorization: Bearer $token" \
  -H 'Content-Type: application/json' --data @"$tmp/yescrypt.json" \
  "$base/api/v2/users" >/dev/null || fail 'cannot create yescrypt user'
sftp --user "yescrypt:$yescrypt_password" --upload-file /work/upload.bin \
  sftp://sftpgo:2022/yescrypt.bin || fail 'yescrypt password login failed'
set +e
sftp --user "yescrypt:$wrong_password" --upload-file /work/upload.bin \
  sftp://sftpgo:2022/denied.bin 2>/dev/null
status=$?
set -e
[ "$status" -eq 67 ] || fail "wrong yescrypt password exited $status, want 67"

# The backup directory is writable by the image user.
curl --fail --silent --max-time 10 -H "Authorization: Bearer $token" \
  "$base/api/v2/dumpdata?output-file=smoke-backup.json" >/dev/null ||
  fail 'dumpdata failed'
docker cp "$server:/srv/sftpgo/backups/smoke-backup.json" "$tmp/backup.json" >/dev/null ||
  fail 'backup was not written to /srv/sftpgo/backups'
jq -e '[.users[].username] | index("smoke") != null' "$tmp/backup.json" >/dev/null ||
  fail 'backup does not contain the smoke user'

# Graceful shutdown on SIGTERM.
docker stop --time 20 "$server" >/dev/null
exit_code=$(docker inspect -f '{{.State.ExitCode}}' "$server")
[ "$exit_code" = 0 ] || fail "exit code after SIGTERM is $exit_code"
docker rm "$server" >/dev/null

# Persistence: a new container on the same volumes keeps the SQLite users
# database, the host key, and the stored file.
start_server
sftp --user "smoke:$user_password" --output /work/persisted.bin \
  sftp://sftpgo:2022/upload.bin || fail 'SFTP download after restart failed'
persisted_sha=$(sha256sum "$tmp/persisted.bin" | cut -d' ' -f1)
[ "$persisted_sha" = "$upload_sha" ] ||
  fail "file after restart has sha256 $persisted_sha, want $upload_sha"
printf 'SFTP DOWNLOAD after restart sha256=%s\n' "$persisted_sha"

printf 'SMOKE PASS image=%s version=%s sha256=%s\n' "$image" "$expected_version" "$upload_sha"
