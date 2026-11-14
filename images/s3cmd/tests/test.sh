#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
config="$(dirname "$0")/../apko.yaml"
version=$(sed -n 's/^    - py3\.[0-9]*-s3cmd=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
# The repository MinIO image is the only S3 endpoint; the pinned index is resolved per platform.
minio_index='ghcr.io/tektum/minio@sha256:0120fdcb5c245d82d62e4214ecb3bab1de114bdf0537e9ec45df1fce3090c898'
label=verity.test=s3cmd-$$
network="verity-s3cmd-network-$$"
minio="verity-s3cmd-minio-$$"
access_key=verityadmin
secret_key=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
work=$(mktemp -d)

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -fv >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  docker logs "$minio" >&2 2>/dev/null || true
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[ -n "$version" ] || fail 'could not read the pinned s3cmd version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/s3cmd"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

docker run --rm --network none --read-only --cap-drop ALL "$image" --version >"$work/version" 2>&1 ||
  fail "version failed: $(cat "$work/version")"
grep -Fx "s3cmd version $version" "$work/version" >/dev/null ||
  fail "version does not report s3cmd $version: $(cat "$work/version")"
test "$(docker run --rm --network none --read-only --cap-drop ALL --entrypoint /usr/bin/python3.13 "$image" \
  -c 'import os; print(os.getuid(), os.getgid())')" = '65532 65532' || fail 'process does not run as 65532:65532'

rc=0
docker run --rm --network none --read-only --cap-drop ALL "$image" --definitely-invalid \
  >"$work/invalid" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'no such option: --definitely-invalid' "$work/invalid" >/dev/null ||
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
  docker pull --quiet --platform "linux/$image_arch" "${1%%@*}@$child" >/dev/null ||
    fail "cannot pull ${1%%@*}@$child"
  printf '%s' "${1%%@*}@$child"
}
minio_image=$(pull_child "$minio_index")

docker network create --label "$label" "$network" >/dev/null
docker run -d --label "$label" --name "$minio" --network "$network" \
  --network-alias minio --read-only \
  --tmpfs /data:uid=65532,gid=65532 --tmpfs /tmp:uid=65532,gid=65532 \
  --tmpfs /home/nonroot:uid=65532,gid=65532 \
  -e MINIO_ROOT_USER="$access_key" -e MINIO_ROOT_PASSWORD="$secret_key" \
  "$minio_image" >/dev/null

# Explicit endpoint and credentials, no ~/.s3cfg: a read-only root with no
# writable HOME, all capabilities dropped, and only the private network.
mkdir "$work/in"
head -c 262144 /dev/urandom >"$work/in/payload.bin"
chmod 755 "$work/in"
chmod 644 "$work/in/payload.bin"
s3() {
  key=$1
  shift
  docker run --rm -i --label "$label" --network "$network" --read-only --cap-drop ALL \
    -v "$work/in:/in:ro" "$image" \
    --access_key="$access_key" --secret_key="$key" \
    --host=minio:9000 --host-bucket=minio:9000 --no-ssl "$@"
}

attempts=0
until s3 "$secret_key" ls >"$work/ready" 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || fail "MinIO did not become ready for s3cmd: $(cat "$work/ready")"
  sleep 1
done

s3 "$secret_key" mb s3://verity-smoke >"$work/mb" 2>&1 ||
  fail "mb failed: $(cat "$work/mb")"
grep -F "Bucket 's3://verity-smoke/' created" "$work/mb" >/dev/null ||
  fail "mb did not report the new bucket: $(cat "$work/mb")"
s3 "$secret_key" ls >"$work/buckets" 2>&1 || fail "bucket listing failed: $(cat "$work/buckets")"
grep -E ' s3://verity-smoke$' "$work/buckets" >/dev/null ||
  fail "bucket listing does not show the bucket: $(cat "$work/buckets")"

s3 "$secret_key" put --no-preserve /in/payload.bin s3://verity-smoke/data/payload.bin \
  >"$work/put" 2>&1 || fail "put failed: $(cat "$work/put")"
grep -F "upload: '/in/payload.bin' -> 's3://verity-smoke/data/payload.bin' (262144 bytes" \
  "$work/put" >/dev/null || fail "put did not report the upload: $(cat "$work/put")"

s3 "$secret_key" ls s3://verity-smoke/data/ >"$work/ls" 2>&1 || fail "ls failed: $(cat "$work/ls")"
grep -E '^[0-9-]+ [0-9:]+ +262144 +s3://verity-smoke/data/payload\.bin$' "$work/ls" >/dev/null ||
  fail "ls does not show the object: $(cat "$work/ls")"

s3 "$secret_key" get --no-progress s3://verity-smoke/data/payload.bin - >"$work/payload.out" 2>"$work/get.err" ||
  fail "get failed: $(cat "$work/get.err")"
cmp "$work/in/payload.bin" "$work/payload.out" >/dev/null ||
  fail 'downloaded object differs from the uploaded bytes'

# Negative: a missing key and a wrong secret key both fail with their diagnostics.
rc=0
s3 "$secret_key" get s3://verity-smoke/data/missing.bin - >"$work/missing" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'get of a missing key unexpectedly succeeded'
grep -F "Source object 's3://verity-smoke/data/missing.bin' does not exist" "$work/missing" >/dev/null ||
  fail "missing key diagnostic is missing: $(cat "$work/missing")"
rc=0
s3 "wrong-$secret_key" ls s3://verity-smoke >"$work/denied" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'a wrong secret key unexpectedly succeeded'
grep -F 'S3 error: 403 (SignatureDoesNotMatch)' "$work/denied" >/dev/null ||
  fail "wrong secret key diagnostic is missing: $(cat "$work/denied")"

printf 'SMOKE PASS image=%s\n' "$image"
