#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
config="$(dirname "$0")/../apko.yaml"
version=$(sed -n 's/^    - azcopy=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
# Azurite is the only Blob endpoint; the pinned index is resolved per platform.
azurite_index='mcr.microsoft.com/azure-storage/azurite:3.37.0@sha256:830430c1da1a2d537e08f3e6764dd1f5ae00cf0346bcaf625b968ec3f0971fd5'
label=verity.test=azcopy-$$
network="verity-azcopy-network-$$"
azurite="verity-azcopy-azurite-$$"
account=verityacct
work=$(mktemp -d)
head -c 32 /dev/urandom >"$work/key"
head -c 32 /dev/urandom >"$work/wrong-key"
key_hex=$(od -An -v -tx1 "$work/key" | tr -d ' \n')
wrong_key_hex=$(od -An -v -tx1 "$work/wrong-key" | tr -d ' \n')
key_b64=$(base64 <"$work/key" | tr -d '\n')
telemetry_off='AZCOPY_TELEMETRY_CONNECTION_STRING=InstrumentationKey=00000000-0000-0000-0000-000000000000'

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -fv >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  docker logs "$azurite" >&2 2>/dev/null || true
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[ -n "$version" ] || fail 'could not read the pinned azcopy version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/azcopy"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" >"$work/env"
grep -Fx "$telemetry_off" "$work/env" >/dev/null ||
  fail "usage telemetry is not disabled by default: $(cat "$work/env")"
grep -Fx 'HOME=/home/nonroot' "$work/env" >/dev/null || fail 'unexpected HOME'

# Offline behavior: no network at all, a read-only root and no capabilities.
offline() {
  docker run --rm --network none --read-only --cap-drop ALL \
    --tmpfs /home/nonroot:uid=65532,gid=65532 "$image" "$@"
}
offline --version >"$work/version" 2>&1 || fail "version failed: $(cat "$work/version")"
grep -Fx "azcopy version $version" "$work/version" >/dev/null ||
  fail "version does not report azcopy $version: $(cat "$work/version")"
offline --help >"$work/help" 2>&1 || fail "help failed: $(cat "$work/help")"
grep -E '^  copy +Copies source data to a destination location$' "$work/help" >/dev/null ||
  fail "help does not list the copy command: $(cat "$work/help")"
# The image HOME must be writable by 65532: AzCopy creates ~/.azcopy at startup.
docker run --rm --network none --cap-drop ALL "$image" env >"$work/home-env" 2>&1 ||
  fail "env with the image HOME failed: $(cat "$work/home-env")"
grep -Fx 'INFO: Name: AZCOPY_JOB_PLAN_LOCATION' "$work/home-env" >/dev/null ||
  fail "env does not list AZCOPY_JOB_PLAN_LOCATION: $(cat "$work/home-env")"
# AzCopy needs writable log and job plan locations under HOME; the
# AZCOPY_LOG_LOCATION and AZCOPY_JOB_PLAN_LOCATION variables move them.
docker run --rm --network none --read-only --cap-drop ALL --tmpfs /tmp:uid=65532,gid=65532 \
  -e AZCOPY_LOG_LOCATION=/tmp/azcopy-logs -e AZCOPY_JOB_PLAN_LOCATION=/tmp/azcopy-plans \
  "$image" env >"$work/azenv" 2>&1 || fail "env failed: $(cat "$work/azenv")"
grep -A1 -Fx 'INFO: Name: AZCOPY_LOG_LOCATION' "$work/azenv" | grep -Fx 'Current Value: /tmp/azcopy-logs' \
  >/dev/null || fail "env does not report AZCOPY_LOG_LOCATION: $(cat "$work/azenv")"
rc=0
docker run --rm --network none --read-only --cap-drop ALL "$image" env >"$work/rofs" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'env unexpectedly succeeded without a writable log location'
grep -F 'Problem making .azcopy directory. Try setting AZCOPY_LOG_LOCATION env variable.' \
  "$work/rofs" >/dev/null || fail "read-only HOME diagnostic is missing: $(cat "$work/rofs")"

# Invalid URLs fail during argument parsing, before any network access.
rc=0
offline copy /etc/hostname 'not-a-url://' >"$work/badurl" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'copy to an invalid destination unexpectedly succeeded'
grep -F 'the inferred source/destination combination could not be identified' \
  "$work/badurl" >/dev/null || fail "invalid destination diagnostic is missing: $(cat "$work/badurl")"
rc=0
offline list 'https://[invalid/container' >"$work/badlist" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'list of an invalid URL unexpectedly succeeded'
grep -F 'azcopy only supports Azure resources for listing' "$work/badlist" >/dev/null ||
  fail "invalid list URL diagnostic is missing: $(cat "$work/badlist")"
rc=0
offline --definitely-invalid >"$work/invalid" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"

# pull_child INDEX: pull the pinned index by its per-platform child digest,
# verifying the index bytes against the pin first so the pin stays authoritative.
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
  repository=${1%%@*}
  repository=${repository%:*}
  docker pull --quiet --platform "linux/$image_arch" "$repository@$child" >/dev/null ||
    fail "cannot pull $repository@$child"
  printf '%s' "$repository@$child"
}
azurite_image=$(pull_child "$azurite_index")

# An internal network has no route out, so neither container can reach real Azure.
# Azurite serves production-style URLs, taking the account from the first host
# label. A host name under the reserved .test domain that contains ".blob" lets
# AzCopy infer the Blob service on its own, exactly as for an Azure endpoint.
host="$account.blob.azurite.test"
docker network create --internal --label "$label" "$network" >/dev/null
docker run -d --label "$label" --name "$azurite" --network "$network" --network-alias "$host" \
  -e AZURITE_ACCOUNTS="$account:$key_b64" "$azurite_image" \
  azurite-blob --blobHost 0.0.0.0 --blobPort 10000 --inMemoryPersistence \
  --disableTelemetry >/dev/null

attempts=0
until docker logs "$azurite" 2>&1 | grep -F 'Azurite Blob service successfully listens on' >/dev/null; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || fail 'Azurite did not become ready'
  sleep 1
done

# sas KEY_HEX: an account SAS for the Blob service signed with KEY_HEX.
expiry=2099-01-01T00:00:00Z
sv=2021-08-06
sas() {
  sig=$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$account" rwdlac b sco '' "$expiry" '' '' "$sv" '' |
    openssl dgst -sha256 -mac HMAC -macopt "hexkey:$1" -binary | base64 | tr -d '\n' |
    sed 's/+/%2B/g; s,/,%2F,g; s/=/%3D/g')
  printf 'sv=%s&ss=b&srt=sco&sp=rwdlac&se=%s&sig=%s' "$sv" "$(printf '%s' "$expiry" | sed 's/:/%3A/g')" "$sig"
}
good_sas=$(sas "$key_hex")
bad_sas=$(sas "$wrong_key_hex")
endpoint="http://$host:10000"

mkdir "$work/in" "$work/out"
head -c 262144 /dev/urandom >"$work/in/payload.bin"
chmod 755 "$work/in"
chmod 777 "$work/out"
chmod 644 "$work/in/payload.bin"
az() {
  docker run --rm --label "$label" --network "$network" --read-only --cap-drop ALL \
    --tmpfs /home/nonroot:uid=65532,gid=65532 \
    -v "$work/in:/in:ro" -v "$work/out:/out" "$image" "$@"
}

az make "$endpoint/smoke?$good_sas" >"$work/make" 2>&1 || fail "make failed: $(cat "$work/make")"
grep -F 'Successfully created the resource.' "$work/make" >/dev/null ||
  fail "make did not report the container: $(cat "$work/make")"

az copy /in/payload.bin "$endpoint/smoke/data/payload.bin?$good_sas" >"$work/up" 2>&1 ||
  fail "upload failed: $(cat "$work/up")"
grep -F 'Number of File Transfers Completed: 1' "$work/up" >/dev/null ||
  fail "upload did not complete one transfer: $(cat "$work/up")"
grep -F 'Final Job Status: Completed' "$work/up" >/dev/null ||
  fail "upload job did not complete: $(cat "$work/up")"

az list "$endpoint/smoke?$good_sas" --machine-readable >"$work/list" 2>&1 ||
  fail "list failed: $(cat "$work/list")"
grep -Fx 'data/payload.bin; Content Length: 262144' "$work/list" >/dev/null ||
  fail "list does not show the uploaded blob: $(cat "$work/list")"

# Azurite 3.37 answers Put Blob From URL with 500, so a service-side blob to
# blob copy cannot be exercised here; the round trip downloads the upload.
az copy "$endpoint/smoke/data/payload.bin?$good_sas" /out/payload.bin >"$work/down" 2>&1 ||
  fail "download failed: $(cat "$work/down")"
grep -F 'Final Job Status: Completed' "$work/down" >/dev/null ||
  fail "download job did not complete: $(cat "$work/down")"
cmp "$work/in/payload.bin" "$work/out/payload.bin" >/dev/null ||
  fail 'downloaded blob differs from the uploaded bytes'

# Negative: a missing blob and a SAS signed with the wrong key both fail.
rc=0
az copy "$endpoint/smoke/data/missing.bin?$good_sas" /out/missing.bin \
  >"$work/missing" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'download of a missing blob unexpectedly succeeded'
rc=0
az list "$endpoint/smoke?$bad_sas" >"$work/denied" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'a SAS signed with the wrong key unexpectedly succeeded'
grep -F 'RESPONSE 403' "$work/denied" >/dev/null ||
  fail "wrong key diagnostic is missing: $(cat "$work/denied")"

az remove "$endpoint/smoke/data/payload.bin?$good_sas" >"$work/remove" 2>&1 ||
  fail "remove failed: $(cat "$work/remove")"
az list "$endpoint/smoke?$good_sas" --machine-readable >"$work/empty" 2>&1 ||
  fail "list after remove failed: $(cat "$work/empty")"
if grep -F 'data/payload.bin' "$work/empty" >/dev/null; then
  fail "list still shows the removed blob: $(cat "$work/empty")"
fi

printf 'SMOKE PASS image=%s\n' "$image"
