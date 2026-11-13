#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
recipe="$here/../melange.yaml"
# The catalog MinIO image is the S3 endpoint; the pinned index is resolved per platform.
minio_index='ghcr.io/tektum/minio@sha256:0120fdcb5c245d82d62e4214ecb3bab1de114bdf0537e9ec45df1fce3090c898'
label="verity-test=s5cmd-$$"
network="verity-s5cmd-network-$$"
server="verity-s5cmd-minio-$$"
volume="verity-s5cmd-data-$$"
access_key=verity-smoke
secret_key=verity-smoke-secret
endpoint=http://minio:9000
bucket=verity-s5cmd-smoke
work=$(mktemp -d)

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -fv >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  docker logs "$server" >&2 2>/dev/null || true
  printf '%s\n' "$1" >&2
  exit 1
}

version=$(sed -n 's/^  version: "\([0-9.]*\)".*$/\1/p' "$recipe")
[ -n "$version" ] || fail 'could not read the recipe version'
commit=$(sed -n 's/^  source-commit: \([0-9a-f]\{40\}\)$/\1/p' "$recipe")
[ -n "$commit" ] || fail 'could not read the recipe source commit'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/s5cmd"]' || fail 'unexpected entrypoint'
case $(docker image inspect --format '{{json .Config.Cmd}}' "$image") in
  null | '[]') ;;
  *) fail 'unexpected image command' ;;
esac
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /aws ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'CA bundle environment is missing'

# stdout only: docker prints a platform mismatch warning on stderr for emulated runs.
out=$(docker run --rm --label "$label" --network none --read-only "$image" version) ||
  fail 'version failed'
expected="v$version-$(printf '%.7s' "$commit")"
test "$out" = "$expected" || fail "version is '$out', expected '$expected'"

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

# An internal network has no route out, so no request can reach real AWS.
docker network create --internal --label "$label" "$network" >/dev/null
docker volume create --label "$label" "$volume" >/dev/null
docker run -d --label "$label" --name "$server" --network "$network" \
  --network-alias minio --read-only \
  --tmpfs /tmp:uid=65532,gid=65532 --tmpfs /home/nonroot:uid=65532,gid=65532 \
  -v "$volume:/data" -e MINIO_ROOT_USER="$access_key" \
  -e MINIO_ROOT_PASSWORD="$secret_key" "$minio_image" >/dev/null

mkdir -p "$work/data"
printf 'verity s5cmd roundtrip\n' >"$work/data/hello.txt"
printf 'verity s5cmd batch\n' >"$work/data/second.txt"
cat >"$work/data/commands.txt" <<EOF
cp s3://$bucket/hello.txt s3://$bucket/batch/copy.txt
cp /aws/second.txt s3://$bucket/batch/second.txt
EOF
chmod -R a+rwX "$work/data"

# s5cmd_as SECRET ARGS...: run the image against MinIO with the given secret key.
s5cmd_as() {
  secret=$1
  shift
  docker run --rm --label "$label" --network "$network" --read-only \
    --tmpfs /tmp:rw,mode=1777 -v "$work/data:/aws" \
    -e AWS_ACCESS_KEY_ID="$access_key" -e AWS_SECRET_ACCESS_KEY="$secret" \
    -e AWS_REGION=us-east-1 -e AWS_EC2_METADATA_DISABLED=true \
    "$image" --endpoint-url "$endpoint" --retry-count 0 "$@"
}
s5() {
  s5cmd_as "$secret_key" "$@"
}

attempts=0
until s5 ls >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || fail 'MinIO did not become ready for s5cmd'
  sleep 1
done

s5 mb "s3://$bucket" >"$work/mb.log" 2>&1 || fail "mb failed: $(cat "$work/mb.log")"
grep -Fx "mb s3://$bucket" "$work/mb.log" >/dev/null ||
  fail "unexpected mb output: $(cat "$work/mb.log")"
s5 ls >"$work/buckets.log" 2>&1 || fail "bucket listing failed: $(cat "$work/buckets.log")"
grep -E "[[:space:]]s3://$bucket\$" "$work/buckets.log" >/dev/null ||
  fail "created bucket is not listed: $(cat "$work/buckets.log")"

s5 cp /aws/hello.txt "s3://$bucket/hello.txt" >"$work/cp.log" 2>&1 ||
  fail "cp upload failed: $(cat "$work/cp.log")"
grep -Fx "cp /aws/hello.txt s3://$bucket/hello.txt" "$work/cp.log" >/dev/null ||
  fail "unexpected cp output: $(cat "$work/cp.log")"

s5 ls "s3://$bucket/" >"$work/ls.log" 2>&1 || fail "ls failed: $(cat "$work/ls.log")"
size=$(wc -c <"$work/data/hello.txt" | tr -d ' ')
grep -E "[[:space:]]${size}[[:space:]]+hello\.txt\$" "$work/ls.log" >/dev/null ||
  fail "uploaded object is not listed with size $size: $(cat "$work/ls.log")"

s5 cat "s3://$bucket/hello.txt" >"$work/cat.out" || fail 'cat failed'
cmp -s "$work/data/hello.txt" "$work/cat.out" ||
  fail "cat returned unexpected content: $(cat "$work/cat.out")"

s5 run /aws/commands.txt >"$work/run.log" 2>&1 || fail "run failed: $(cat "$work/run.log")"
grep -Fx "cp s3://$bucket/hello.txt s3://$bucket/batch/copy.txt" "$work/run.log" >/dev/null ||
  fail "batch server-side copy did not run: $(cat "$work/run.log")"
grep -Fx "cp /aws/second.txt s3://$bucket/batch/second.txt" "$work/run.log" >/dev/null ||
  fail "batch upload did not run: $(cat "$work/run.log")"
s5 cat "s3://$bucket/batch/copy.txt" >"$work/copy.out" || fail 'cat of batch copy failed'
cmp -s "$work/data/hello.txt" "$work/copy.out" || fail 'batch copy has unexpected content'
s5 cat "s3://$bucket/batch/second.txt" >"$work/second.out" || fail 'cat of batch upload failed'
cmp -s "$work/data/second.txt" "$work/second.out" || fail 'batch upload has unexpected content'

s5 rm "s3://$bucket/hello.txt" >"$work/rm.log" 2>&1 || fail "rm failed: $(cat "$work/rm.log")"
grep -Fx "rm s3://$bucket/hello.txt" "$work/rm.log" >/dev/null ||
  fail "unexpected rm output: $(cat "$work/rm.log")"
s5 ls "s3://$bucket/*" >"$work/after-rm.log" 2>&1 || fail "ls after rm failed: $(cat "$work/after-rm.log")"
if grep -E '[[:space:]]hello\.txt$' "$work/after-rm.log" >/dev/null; then
  fail "removed object is still listed: $(cat "$work/after-rm.log")"
fi
grep -E '[[:space:]]batch/copy\.txt$' "$work/after-rm.log" >/dev/null ||
  fail "rm removed more than the target object: $(cat "$work/after-rm.log")"

# Negative: a wrong secret key is rejected by the server's signature check.
if s5cmd_as wrong-secret-key ls "s3://$bucket/" >"$work/denied.log" 2>&1; then
  fail 'listing with a wrong secret key succeeded'
fi
grep -E '(SignatureDoesNotMatch|AccessDenied).*status code: 403' "$work/denied.log" >/dev/null ||
  fail "unexpected wrong-secret error: $(cat "$work/denied.log")"

# Negative: a missing bucket is reported as such.
if s5 ls "s3://verity-s5cmd-missing/" >"$work/missing.log" 2>&1; then
  fail 'listing a missing bucket succeeded'
fi
grep -E 'NoSuchBucket.*status code: 404' "$work/missing.log" >/dev/null ||
  fail "unexpected missing-bucket error: $(cat "$work/missing.log")"

printf 'SMOKE PASS\n'
