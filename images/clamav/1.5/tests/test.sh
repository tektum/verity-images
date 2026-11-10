#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
recipe="$(dirname "$0")/../melange.yaml"
version=$(sed -n 's/^  version: "\([^"]*\)".*$/\1/p' "$recipe")
[ -n "$version" ] || { printf 'package version not found in melange.yaml\n' >&2; exit 1; }

prefix=clamav-test-$$
label="verity-test=$prefix"
daemon=$prefix-daemon
tmp=$(mktemp -d)

cleanup() {
  docker rm -f "$daemon" >/dev/null 2>&1 || :
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# Every container runs without a network: the test needs neither freshclam nor
# any download, so it proves the image works offline.
run() {
  docker run --rm --label "$label" --network none "$@"
}

test "$(docker image inspect "$image" --format '{{.Config.User}}')" = 100 || fail 'image does not run as uid 100'
out=$(run --entrypoint id "$image") || fail 'id failed'
printf '%s\n' "$out" | grep -F 'uid=100(clamav) gid=100(clamav)' > /dev/null || fail "unexpected identity: $out"
test "$(docker image inspect "$image" --format '{{.Config.Entrypoint}}')" = '[/usr/bin/docker-entrypoint.sh]' || fail 'unexpected entrypoint'

# Fixtures. The EICAR string is written at test time and never committed. The
# signature database is a single hash signature generated from it with sigtool.
mkdir "$tmp/db" "$tmp/scan" "$tmp/emptydb" "$tmp/baddb"
# shellcheck disable=SC2016  # the EICAR string contains a literal dollar sign
printf '%s\n' 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' > "$tmp/scan/eicar.txt"
printf 'hello, this file is clean\n' > "$tmp/scan/clean.txt"
printf 'this is not a signature\n' > "$tmp/baddb/bad.hdb"
chmod 755 "$tmp" "$tmp/db" "$tmp/scan" "$tmp/emptydb" "$tmp/baddb"
chmod 644 "$tmp/scan/eicar.txt" "$tmp/scan/clean.txt" "$tmp/baddb/bad.hdb"

# Tool versions. freshclam is only asked for its version: the test never updates signatures.
for tool in clamscan clamd clamdscan freshclam sigtool; do
  out=$(run --entrypoint "$tool" "$image" --version 2>&1) || fail "$tool --version failed: $out"
  printf '%s\n' "$out" | grep -F "ClamAV $version" > /dev/null || fail "$tool reports '$out', expected ClamAV $version"
done
# Arguments that name a command in PATH run it (entrypoint passthrough).
out=$(run "$image" clamscan --version) || fail 'entrypoint passthrough failed'
printf '%s\n' "$out" | grep -F "ClamAV $version" > /dev/null || fail "passthrough reports '$out'"

# Build the signature database inside the image.
run -v "$tmp/scan:/scan:ro" "$image" sigtool --md5 /scan/eicar.txt \
  | sed 's/:[^:]*$/:Verity.Test.EICAR/' > "$tmp/db/test.hdb"
grep -E '^[0-9a-f]{32}:[0-9]+:Verity\.Test\.EICAR$' "$tmp/db/test.hdb" > /dev/null \
  || fail "unexpected signature line: $(cat "$tmp/db/test.hdb")"
chmod 644 "$tmp/db/test.hdb"

# ClamAV marks signatures from an unsigned database as UNOFFICIAL.
# clamscan: infected file exits 1 and names the signature, clean file exits 0.
status=0
out=$(run -v "$tmp/db:/db:ro" -v "$tmp/scan:/scan:ro" "$image" clamscan --no-summary -d /db /scan/eicar.txt 2>&1) || status=$?
printf '%s\n' "$out"
test "$status" -eq 1 || fail "clamscan on EICAR exited $status, expected 1"
printf '%s\n' "$out" | grep -F 'eicar.txt: Verity.Test.EICAR.UNOFFICIAL FOUND' > /dev/null || fail 'clamscan did not report the signature'
status=0
out=$(run -v "$tmp/db:/db:ro" -v "$tmp/scan:/scan:ro" "$image" clamscan --no-summary -d /db /scan/clean.txt 2>&1) || status=$?
printf '%s\n' "$out"
test "$status" -eq 0 || fail "clamscan on a clean file exited $status, expected 0"
printf '%s\n' "$out" | grep -F 'clean.txt: OK' > /dev/null || fail 'clamscan did not report OK for the clean file'

# clamd: default entrypoint and shipped configuration, daemon started on the test database.
docker run -d --name "$daemon" --label "$label" --network none \
  -v "$tmp/db:/var/lib/clamav:ro" -v "$tmp/scan:/scan:ro" "$image" > /dev/null
ready=0
for _ in $(seq 1 60); do
  if docker exec "$daemon" clamdscan --ping 1:1 > /dev/null 2>&1; then
    ready=1
    break
  fi
  if [ "$(docker inspect --format '{{.State.Running}}' "$daemon")" != true ]; then
    docker logs "$daemon" >&2 || :
    fail 'clamd exited before it became ready'
  fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  docker logs "$daemon" >&2 || :
  fail 'clamd did not answer PING'
fi

# The shipped TCP listener on port 3310: a second client configuration that
# connects over TCP instead of the local socket.
docker exec "$daemon" sh -c 'printf "TCPSocket 3310\nTCPAddr 127.0.0.1\n" > /tmp/tcp.conf'
docker exec "$daemon" clamdscan --config-file=/tmp/tcp.conf --ping 5:1 > /dev/null || fail 'clamd does not answer on TCP 3310'
status=0
out=$(docker exec "$daemon" clamdscan --config-file=/tmp/tcp.conf --no-summary --stream /scan/eicar.txt 2>&1) || status=$?
test "$status" -eq 1 || fail "TCP clamdscan on EICAR exited $status, expected 1"
printf '%s\n' "$out" | grep -F 'Verity.Test.EICAR.UNOFFICIAL FOUND' > /dev/null || fail 'TCP clamdscan did not report the signature'

# The client on the local socket.
status=0
out=$(docker exec "$daemon" clamdscan --no-summary /scan/eicar.txt 2>&1) || status=$?
printf '%s\n' "$out"
test "$status" -eq 1 || fail "clamdscan on EICAR exited $status, expected 1"
printf '%s\n' "$out" | grep -F 'eicar.txt: Verity.Test.EICAR.UNOFFICIAL FOUND' > /dev/null || fail 'clamdscan did not report the signature'
status=0
out=$(docker exec "$daemon" clamdscan --no-summary /scan/clean.txt 2>&1) || status=$?
printf '%s\n' "$out"
test "$status" -eq 0 || fail "clamdscan on a clean file exited $status, expected 0"
printf '%s\n' "$out" | grep -F 'clean.txt: OK' > /dev/null || fail 'clamdscan did not report OK for the clean file'
# The same through the streaming path, which does not need file access from clamd.
status=0
out=$(docker exec "$daemon" clamdscan --no-summary --stream /scan/eicar.txt 2>&1) || status=$?
test "$status" -eq 1 || fail "clamdscan --stream on EICAR exited $status, expected 1"
printf '%s\n' "$out" | grep -F 'Verity.Test.EICAR.UNOFFICIAL FOUND' > /dev/null || fail 'clamdscan --stream did not report the signature'
docker stop --time 20 "$daemon" > /dev/null
test "$(docker inspect --format '{{.State.ExitCode}}' "$daemon")" -eq 0 || fail 'clamd did not exit cleanly on SIGTERM'
docker rm "$daemon" > /dev/null

# Negative: no database, and an unreadable database, must stop clamd with a readable error.
status=0
out=$(run -v "$tmp/emptydb:/var/lib/clamav:ro" "$image" 2>&1) || status=$?
printf '%s\n' "$out"
test "$status" -ne 0 || fail 'clamd started without a database'
printf '%s\n' "$out" | grep -Ei 'no supported database|can.t open|not found' > /dev/null \
  || fail 'clamd gave no readable error for a missing database'
status=0
out=$(run -v "$tmp/baddb:/var/lib/clamav:ro" "$image" 2>&1) || status=$?
printf '%s\n' "$out"
test "$status" -ne 0 || fail 'clamd started with an invalid database'
printf '%s\n' "$out" | grep -Ei 'error' > /dev/null || fail 'clamd gave no readable error for an invalid database'

printf 'clamav %s smoke test passed\n' "$version"
