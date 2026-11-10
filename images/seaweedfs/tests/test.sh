#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)"$/\1/p' \
  "$(dirname "$0")/../melange.yaml" | sed -n 1p)
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
container="verity-seaweedfs-test-$$"
volume="verity-seaweedfs-test-$$"
work=$(mktemp -d)
access_key=verityaccess
secret_key=veritysecret

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  docker logs "$container" >&2 2>&1 || true
  exit 1
}

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /data ] || fail 'unexpected OCI working directory'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' "$image")" = \
  '["/entrypoint.sh"] ["server","-s3"]' ] || fail 'unexpected OCI command'

version=$(docker run --rm --network none "$image" version)
case "$version" in
  *"$expected_version"*) ;;
  *) fail "weed version '$version' does not contain $expected_version" ;;
esac

# The entrypoint must not force FIPS mode on in this plain image.
docker run --rm --network none --entrypoint /bin/sh "$image" -c 'grep -q fips140 /entrypoint.sh' &&
  fail 'entrypoint still forces GODEBUG fips140'

# Negative: an unknown subcommand exits non-zero with a readable error.
if docker run --rm --network none "$image" nosuchcommand >"$work/bad.log" 2>&1; then
  fail 'unknown subcommand unexpectedly succeeded'
fi
grep -q 'unknown subcommand' "$work/bad.log" || { cat "$work/bad.log" >&2; fail 'unknown subcommand error is not readable'; }

start_server() {
  docker run --name "$container" -d --read-only --tmpfs /tmp:uid=65532,gid=65532 \
    -v "$volume:/data" -e AWS_ACCESS_KEY_ID="$access_key" -e AWS_SECRET_ACCESS_KEY="$secret_key" \
    -p 127.0.0.1::8333 -p 127.0.0.1::9333 "$image" >/dev/null
  s3_port=$(docker port "$container" 8333/tcp | awk -F: 'NR == 1 { print $NF }')
  master_port=$(docker port "$container" 9333/tcp | awk -F: 'NR == 1 { print $NF }')
  [ -n "$s3_port" ] && [ -n "$master_port" ] || fail 'no published ports'
  s3="http://127.0.0.1:$s3_port"
  i=0
  until curl --fail --silent --max-time 5 "http://127.0.0.1:$master_port/cluster/status" 2>/dev/null |
    grep -q '"IsLeader":true'; do
    i=$((i + 1))
    [ "$i" -lt 120 ] || fail 'master never became leader on :9333'
    sleep 1
  done
}

s3curl() {
  curl --silent --max-time 30 --aws-sigv4 aws:amz:us-east-1:s3 --user "$access_key:$secret_key" "$@"
}

printf 'verity-seaweedfs-payload\n' >"$work/object.txt"
start_server

# Bucket creation can race the S3 gateway coming up behind the master, so retry it.
i=0
until [ "$(s3curl --output /dev/null --write-out '%{http_code}' -X PUT "$s3/verity-bucket")" = 200 ]; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'bucket creation never succeeded on :8333'
  sleep 1
done
status=$(s3curl --output /dev/null --write-out '%{http_code}' -X PUT --data-binary "@$work/object.txt" \
  "$s3/verity-bucket/dir/object.txt")
[ "$status" = 200 ] || fail "object PUT returned $status, want 200"
s3curl --fail --output "$work/got.txt" "$s3/verity-bucket/dir/object.txt" || fail 'object GET failed'
cmp "$work/object.txt" "$work/got.txt" || fail 'object body differs from what was stored'

# Unsigned and wrongly signed requests are refused.
status=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 20 "$s3/verity-bucket/dir/object.txt")
[ "$status" = 403 ] || fail "anonymous GET returned $status, want 403"
status=$(curl --silent --output "$work/badsig.xml" --write-out '%{http_code}' --max-time 20 \
  --aws-sigv4 aws:amz:us-east-1:s3 --user "$access_key:wrong" "$s3/verity-bucket/dir/object.txt")
[ "$status" = 403 ] || fail "wrongly signed GET returned $status, want 403"
grep -q 'SignatureDoesNotMatch' "$work/badsig.xml" || fail 'wrong signature error is not readable'

# Missing key is a readable 404.
status=$(s3curl --output "$work/missing.xml" --write-out '%{http_code}' "$s3/verity-bucket/no/such/key")
[ "$status" = 404 ] || fail "missing key returned $status, want 404"
grep -q 'NoSuchKey' "$work/missing.xml" || fail 'missing key error is not readable'

# SIGTERM stops the whole process cleanly.
docker stop -t 90 "$container" >/dev/null
[ "$(docker inspect -f '{{.State.ExitCode}}' "$container")" = 0 ] ||
  fail "weed exited with $(docker inspect -f '{{.State.ExitCode}}' "$container") on SIGTERM"
docker rm "$container" >/dev/null

# Persistence: the object survives a restart on the same volume.
start_server
i=0
until s3curl --fail --output "$work/after.txt" "$s3/verity-bucket/dir/object.txt" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'object did not survive a restart'
  sleep 1
done
cmp "$work/object.txt" "$work/after.txt" || fail 'object body changed across a restart'

printf 'SMOKE PASS image=%s\n' "$image"
