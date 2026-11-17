#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d)
containers=''

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  for container in $containers; do
    docker rm -f "$container" >/dev/null 2>&1 || true
  done
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

version=$(sed -n 's/^    - docker-credential-gcr=\([0-9.]*\)-r[0-9]*$/\1/p' "$here/../apko.yaml")
[ -n "$version" ] || fail 'could not read the pinned docker-credential-gcr version'
# The helper derives its Docker username from its own version.
username="_dcgcr_$(printf '%s' "$version" | tr . _)_token"

test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/docker-credential-gcr"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
docker image inspect --format '{{json .Config.Env}}' "$image" | grep -F '"HOME=/home/nonroot"' >/dev/null ||
  fail 'HOME is not /home/nonroot'

# Every run is offline: no network, so neither the GCE metadata server nor any
# Google endpoint is reachable, and the image ships no gcloud. Each run is
# bounded so a helper that waits on the network fails the test instead of
# hanging it; status 124 means the bound was hit.
offline='--network none --cap-drop=ALL --security-opt no-new-privileges'

# run NAME STDIN [docker run options...] -- [helper arguments...]
# Runs the helper on a read-only root file system with a tmpfs HOME, the given
# string on stdin, and records NAME.out, NAME.err, and the exit status.
run() {
  name=$1
  input=$2
  shift 2
  status=0
  # shellcheck disable=SC2086
  printf '%s' "$input" | timeout 120 docker run --rm -i $offline --read-only \
    --tmpfs /home/nonroot:rw,uid=65532,gid=65532,mode=0755 --tmpfs /tmp:rw,mode=1777 \
    "$@" >"$work/$name.out" 2>"$work/$name.err" || status=$?
  test "$status" -ne 124 || fail "$name timed out offline"
}

# persist NAME [docker run options...] -- [helper arguments...]
# Runs the helper with its writable image HOME and keeps the container, so
# files it writes as uid 65532 can be copied out with `docker cp`.
persist() {
  name=$1
  shift
  container="docker-credential-gcr-smoke-$$-$name"
  containers="$containers $container"
  # shellcheck disable=SC2086
  docker create --name "$container" $offline "$@" >/dev/null || fail "$name: create failed"
  status=0
  timeout 120 docker start -a "$container" </dev/null >"$work/$name.out" 2>"$work/$name.err" ||
    status=$?
  test "$status" -ne 124 || fail "$name timed out offline"
}

copy_out() {
  docker cp "$1:$2" - | tar -xOf -
}

expect_status() {
  test "$status" = "$2" || fail "$1 exited $status, want $2: $(cat "$work/$1.out" "$work/$1.err")"
}

expect_line() {
  grep -Fx -- "$3" "$work/$1.$2" >/dev/null || fail "$1 $2 lacks '$3': $(cat "$work/$1.$2")"
}

expect_text() {
  grep -F -- "$3" "$work/$1.$2" >/dev/null || fail "$1 $2 lacks '$3': $(cat "$work/$1.$2")"
}

run version '' "$image" version
expect_status version 0
expect_line version out "Google Container Registry Docker credential helper $version"

run unknown '' "$image" definitely-not-a-command
expect_status unknown 2
expect_text unknown err 'Subcommands for Docker credential store API:'

# Docker credential-helper protocol. Errors go to stdout with status 1, which
# is how Docker reads a helper failure.
# `list`, `store`, and `erase` are unimplemented upstream: they fail and write
# nothing.
mkdir -p "$work/noop"
chmod 0777 "$work/noop"
run list '' -v "$work/noop:/state" -e HOME=/state "$image" list
expect_status list 1
expect_line list out 'list is unimplemented'
run store '{"ServerURL":"gcr.io","Username":"user","Secret":"secret"}' \
  -v "$work/noop:/state" -e HOME=/state "$image" store
expect_status store 1
expect_line store out 'add is unimplemented'
run erase 'gcr.io' -v "$work/noop:/state" -e HOME=/state "$image" erase
expect_status erase 1
expect_line erase out 'delete is unimplemented'
test -z "$(ls -A "$work/noop")" || fail "list, store, or erase wrote state: $(ls -A "$work/noop")"

run get-empty '' "$image" get
expect_status get-empty 1
expect_line get-empty out 'no credentials server URL'

# Unconfigured: no stored token, no application default credentials, no
# metadata server. Every server, GCR or not, takes the error path and no
# credential JSON is printed.
for server in gcr.io us-docker.pkg.dev registry-1.docker.io; do
  run get-unconfigured "$server" "$image" get
  expect_status get-unconfigured 1
  expect_text get-unconfigured out "could not retrieve GCR's access token"
  expect_text get-unconfigured out 'could not find default credentials'
  ! grep -F '"Secret"' "$work/get-unconfigured.out" >/dev/null ||
    fail "get $server printed credentials while unconfigured"
done

# The gcloud token source shells out to gcloud, which the image does not ship.
mkdir -p "$work/config"
printf '{"TokenSources":["gcloud"]}\n' >"$work/config/gcloud.json"
printf '{"TokenSources":["bogus"]}\n' >"$work/config/bogus.json"
chmod 0644 "$work/config/gcloud.json" "$work/config/bogus.json"
run get-gcloud gcr.io -v "$work/config:/config:ro" \
  -e DOCKER_CREDENTIAL_GCR_CONFIG=/config/gcloud.json "$image" get
expect_status get-gcloud 1
# shellcheck disable=SC2016 # literal backticks in the upstream message
expect_text get-gcloud out '`gcloud config config-helper` failed'
expect_text get-gcloud out 'executable file not found'
run get-bogus gcr.io -v "$work/config:/config:ro" \
  -e DOCKER_CREDENTIAL_GCR_CONFIG=/config/bogus.json "$image" get
expect_status get-bogus 1
expect_text get-bogus out 'unknown token source: bogus'

# The store token source serves an unexpired cached access token without any
# network call. The helper ignores the server URL, so it answers for any host.
mkdir -p "$work/store"
cat >"$work/store/valid.json" <<'JSON'
{"gcrCreds":{"access_token":"ya29.verity-smoke-access-token","refresh_token":"verity-smoke-refresh","token_expiry":"2999-01-01T00:00:00Z"}}
JSON
cat >"$work/store/expired.json" <<'JSON'
{"gcrCreds":{"access_token":"ya29.verity-smoke-expired","refresh_token":"verity-smoke-refresh","token_expiry":"2000-01-01T00:00:00Z"}}
JSON
chmod 0644 "$work/store/valid.json" "$work/store/expired.json"
for server in gcr.io europe-docker.pkg.dev; do
  run get-store "$server" -v "$work/store:/store:ro" \
    -e DOCKER_CREDENTIAL_GCR_STORE=/store/valid.json "$image" get
  expect_status get-store 0
  test "$(jq -c . "$work/get-store.out")" = \
    "{\"ServerURL\":\"$server\",\"Username\":\"$username\",\"Secret\":\"ya29.verity-smoke-access-token\"}" ||
    fail "get $server from the store returned: $(cat "$work/get-store.out")"
done

# An expired cached token needs a refresh from Google; offline it must fail
# promptly instead of hanging or falling back to the stale token.
printf '{"TokenSources":["store"]}\n' >"$work/config/store.json"
chmod 0644 "$work/config/store.json"
run get-expired gcr.io -v "$work/store:/store:ro" -v "$work/config:/config:ro" \
  -e DOCKER_CREDENTIAL_GCR_STORE=/store/expired.json \
  -e DOCKER_CREDENTIAL_GCR_CONFIG=/config/store.json "$image" get
expect_status get-expired 1
expect_text get-expired out "could not retrieve GCR's access token"
! grep -F 'verity-smoke-expired' "$work/get-expired.out" >/dev/null ||
  fail 'get served an expired token'

# The env token source signs a self-signed JWT locally from a service account
# key, so it also works with no network. Verify the claims and the signature.
mkdir -p "$work/sa"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$work/sa/key.pem" 2>/dev/null ||
  fail 'could not generate a service account key'
openssl pkey -in "$work/sa/key.pem" -pubout -out "$work/sa/pub.pem" ||
  fail 'could not derive the public key'
client_email=smoke@verity-smoke.iam.gserviceaccount.com
jq -n --rawfile key "$work/sa/key.pem" --arg email "$client_email" '{
  type: "service_account", project_id: "verity-smoke", private_key_id: "0123456789abcdef",
  private_key: $key, client_email: $email, client_id: "1",
  token_uri: "https://oauth2.googleapis.com/token"
}' >"$work/sa/key.json"
chmod 0644 "$work/sa/key.json"
run get-env gcr.io -v "$work/sa/key.json:/sa/key.json:ro" \
  -e GOOGLE_APPLICATION_CREDENTIALS=/sa/key.json "$image" get
expect_status get-env 0
test "$(jq -r '.ServerURL + " " + .Username' "$work/get-env.out")" = "gcr.io $username" ||
  fail "get with a service account returned: $(cat "$work/get-env.out")"
jwt=$(jq -r .Secret "$work/get-env.out")
b64url_decode() {
  value=$(printf '%s' "$1" | tr '_-' '/+')
  case $((${#value} % 4)) in
    2) value="$value==" ;;
    3) value="$value=" ;;
  esac
  printf '%s' "$value" | openssl base64 -d -A
}
header=$(printf '%s' "$jwt" | cut -d. -f1)
payload=$(printf '%s' "$jwt" | cut -d. -f2)
b64url_decode "$(printf '%s' "$jwt" | cut -d. -f3)" >"$work/sa/signature"
b64url_decode "$header" | jq -e '.alg == "RS256" and .kid == "0123456789abcdef"' >/dev/null ||
  fail "unexpected JWT header: $(b64url_decode "$header")"
b64url_decode "$payload" | jq -e --arg email "$client_email" \
  '.iss == $email and .sub == $email and
   .scope == "https://www.googleapis.com/auth/devstorage.read_write" and .exp > .iat' >/dev/null ||
  fail "unexpected JWT claims: $(b64url_decode "$payload")"
printf '%s.%s' "$header" "$payload" |
  openssl dgst -sha256 -verify "$work/sa/pub.pem" -signature "$work/sa/signature" >/dev/null ||
  fail 'the JWT is not signed by the service account key'

# config --token-source persists the ordered sources in the image HOME.
persist config-set "$image" config --token-source='env, store'
expect_status config-set 0
expect_line config-set out 'Success: Token source(s) set.'
test "$(copy_out "$container" /home/nonroot/.config/gcloud/docker_credential_gcr_config.json | jq -c .)" = \
  '{"TokenSources":["env","store"]}' || fail 'config did not write the token sources'

# An unsupported source is rejected and writes no config file.
persist config-bad "$image" config --token-source=metadata
expect_status config-bad 1
expect_line config-bad err 'Failure: token-source: Unsupported token source: metadata'
! docker cp "$container:/home/nonroot/.config" - >/dev/null 2>&1 ||
  fail 'a rejected token source still wrote a config file'

# DOCKER_CREDENTIAL_GCR_CONFIG relocates the file; --unset-all removes it.
mkdir -p "$work/relocated"
chmod 0777 "$work/relocated"
run config-env '' -v "$work/relocated:/state" -e DOCKER_CREDENTIAL_GCR_CONFIG=/state/helper.json \
  "$image" config --token-source=gcloud
expect_status config-env 0
test "$(jq -c . "$work/relocated/helper.json")" = '{"TokenSources":["gcloud"]}' ||
  fail "relocated config holds: $(cat "$work/relocated/helper.json")"
run config-reset '' -v "$work/relocated:/state" -e DOCKER_CREDENTIAL_GCR_CONFIG=/state/helper.json \
  "$image" config --unset-all
expect_status config-reset 0
expect_line config-reset out 'Success: Config reset.'
test ! -e "$work/relocated/helper.json" || fail 'config --unset-all kept the config file'

# configure-docker with no registries writes every GCR host into the image
# user's Docker config.
persist docker-default "$image" configure-docker
expect_status docker-default 0
expect_line docker-default out '/home/nonroot/.docker/config.json configured to use this credential helper for GCR registries'
copy_out "$container" /home/nonroot/.docker/config.json >"$work/docker-default.json" ||
  fail 'configure-docker wrote no Docker config'
test "$(jq -c '.credHelpers' "$work/docker-default.json")" = \
  '{"asia.gcr.io":"gcr","eu.gcr.io":"gcr","gcr.io":"gcr","marketplace.gcr.io":"gcr","us.gcr.io":"gcr"}' ||
  fail "unexpected default credHelpers: $(cat "$work/docker-default.json")"

persist docker-ar "$image" configure-docker --include-artifact-registry
expect_status docker-ar 0
copy_out "$container" /home/nonroot/.docker/config.json >"$work/docker-ar.json" ||
  fail 'configure-docker --include-artifact-registry wrote no Docker config'
jq -e '.credHelpers as $h |
  ([$h[]] | unique) == ["gcr"] and $h["gcr.io"] == "gcr" and
  $h["us-docker.pkg.dev"] == "gcr" and $h["europe-west1-docker.pkg.dev"] == "gcr" and
  ($h | length) > 50' "$work/docker-ar.json" >/dev/null ||
  fail "Artifact Registry hosts are missing: $(cat "$work/docker-ar.json")"

# --registries under DOCKER_CONFIG merges into an existing config and keeps
# unrelated auths and credential helpers.
mkdir -p "$work/docker"
printf '{"auths":{"ghcr.io":{"auth":"dmVyaXR5OnNtb2tl"}},"credHelpers":{"quay.io":"other"}}\n' \
  >"$work/docker/config.json"
chmod 0777 "$work/docker"
chmod 0666 "$work/docker/config.json"
run docker-merge '' -v "$work/docker:/docker" -e DOCKER_CONFIG=/docker \
  "$image" configure-docker --registries='us-docker.pkg.dev, gcr.io'
expect_status docker-merge 0
expect_line docker-merge out 'Adding config for registries: us-docker.pkg.dev, gcr.io'
test "$(jq -c '{auths, credHelpers}' "$work/docker/config.json")" = \
  '{"auths":{"ghcr.io":{"auth":"dmVyaXR5OnNtb2tl"}},"credHelpers":{"gcr.io":"gcr","quay.io":"other","us-docker.pkg.dev":"gcr"}}' ||
  fail "configure-docker did not merge: $(cat "$work/docker/config.json")"

# gcr-logout drops the stored GCR token offline, after which get fails.
mkdir -p "$work/logout"
cp "$work/store/valid.json" "$work/logout/creds.json"
chmod 0777 "$work/logout"
chmod 0666 "$work/logout/creds.json"
run logout '' -v "$work/logout:/state" -e DOCKER_CREDENTIAL_GCR_STORE=/state/creds.json \
  "$image" gcr-logout
expect_status logout 0
jq -e 'has("gcrCreds") | not' "$work/logout/creds.json" >/dev/null ||
  fail "gcr-logout kept the token: $(cat "$work/logout/creds.json")"
run get-logout gcr.io -v "$work/logout:/state" -e DOCKER_CREDENTIAL_GCR_STORE=/state/creds.json \
  "$image" get
expect_status get-logout 1
expect_text get-logout out "could not retrieve GCR's access token"

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$version"
