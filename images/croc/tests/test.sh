#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
config="$(dirname "$0")/../apko.yaml"
version=$(sed -n 's/^    - croc=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
id=$$
network="verity-croc-$id"
relay="verity-croc-relay-$id"
sender="verity-croc-send-$id"
sender2="verity-croc-send2-$id"
work=$(mktemp -d)
pass=relay-pass-$id
code=4821-verity-smoke-$id
code2=4821-verity-second-$id

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  for c in "$relay" "$sender" "$sender2"; do
    docker logs "$c" 2>&1 | tail -n 20 >&2 || true
  done
  exit 1
}

cleanup() {
  docker rm -f "$relay" "$sender" "$sender2" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail 'could not read the pinned croc version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/croc"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["relay"]' ||
  fail 'unexpected command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

docker run --rm --network none "$image" --version >"$work/version" 2>&1 ||
  fail 'version failed'
grep -Fx "croc version $version" "$work/version" >/dev/null ||
  fail "version does not report croc $version: $(cat "$work/version")"

rc=0
docker run --rm --network none "$image" --definitely-invalid >"$work/invalid" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'flag provided but not defined' "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"

mkdir -p "$work/in" "$work/out" "$work/wrong"
head -c 1048576 /dev/urandom >"$work/in/payload.bin"
chmod 755 "$work/in"
chmod 644 "$work/in/payload.bin"
chmod 777 "$work/out" "$work/wrong"
want=$(sha256sum "$work/in/payload.bin" | awk '{print $1}')

docker network create "$network" >/dev/null

# Default command: the relay, on a read-only root with no capabilities.
docker run -d --name "$relay" --network "$network" --read-only --cap-drop=ALL \
  --tmpfs /home/nonroot:rw,uid=65532,gid=65532 -e CROC_PASS="$pass" "$image" >/dev/null
ready=false
i=0
while [ "$i" -lt 30 ]; do
  if docker logs "$relay" 2>&1 | grep -F 'starting TCP server on :9009' >/dev/null; then
    ready=true
    break
  fi
  i=$((i + 1))
  sleep 1
done
"$ready" || fail 'relay did not start'

# Sender and receiver are separate containers that meet only through the relay.
docker run -d --name "$sender" --network "$network" --read-only --cap-drop=ALL \
  --tmpfs /tmp:rw,mode=1777 --tmpfs /home/nonroot:rw,uid=65532,gid=65532 -v "$work/in:/in:ro" -e CROC_SECRET="$code" "$image" \
  --relay "$relay:9009" --pass "$pass" --yes --no-update-check send --no-local /in/payload.bin >/dev/null
i=0
until docker logs "$sender" 2>&1 | grep -F "code=$code" >/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail 'sender did not register with the relay'
  sleep 1
done

# The receiver runs with the image's own writable root and /home/nonroot.
docker run --rm --network "$network" --cap-drop=ALL \
  -v "$work/out:/work" -e CROC_SECRET="$code" "$image" \
  --relay "$relay:9009" --pass "$pass" --yes --no-update-check --overwrite >"$work/recv.log" 2>&1 ||
  fail "receive failed: $(cat "$work/recv.log")"
test -f "$work/out/payload.bin" || fail 'received file is missing'
got=$(sha256sum "$work/out/payload.bin" | awk '{print $1}')
test "$got" = "$want" || fail "checksum mismatch: got $got want $want"

code_rc=$(docker wait "$sender")
test "$code_rc" -eq 0 || fail "sender exit code $code_rc"

# A receiver with a wrong code in the same relay room (croc picks the room from
# the first four characters) must fail and must not write the file. A failed
# handshake aborts the sender, so this case uses its own sender.
docker run -d --name "$sender2" --network "$network" --read-only --cap-drop=ALL \
  --tmpfs /tmp:rw,mode=1777 --tmpfs /home/nonroot:rw,uid=65532,gid=65532 -v "$work/in:/in:ro" -e CROC_SECRET="$code2" "$image" \
  --relay "$relay:9009" --pass "$pass" --yes --no-update-check send --no-local /in/payload.bin >/dev/null
i=0
until docker logs "$sender2" 2>&1 | grep -F "code=$code2" >/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail 'second sender did not register with the relay'
  sleep 1
done
rc=0
docker run --rm --network "$network" --read-only --cap-drop=ALL --tmpfs /tmp:rw,mode=1777 --tmpfs /home/nonroot:rw,uid=65532,gid=65532 \
  -v "$work/wrong:/work" -e CROC_SECRET="4821-wrong-code-$id" "$image" \
  --relay "$relay:9009" --pass "$pass" --yes --no-update-check >"$work/wrong.log" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'receiver with a wrong code unexpectedly succeeded'
test ! -e "$work/wrong/payload.bin" || fail 'receiver with a wrong code wrote the file'
grep -F 'Receiving' "$work/wrong.log" >/dev/null && fail 'receiver with a wrong code started a transfer'
docker rm -f "$sender2" >/dev/null 2>&1 || true

# The relay keeps serving after the transfer and stops cleanly on SIGTERM.
docker inspect --format '{{.State.Running}}' "$relay" | grep -Fx true >/dev/null ||
  fail 'relay exited after the transfer'
docker stop -t 10 "$relay" >/dev/null
rc=$(docker inspect --format '{{.State.ExitCode}}' "$relay")
case "$rc" in
  0 | 143) ;;
  *) fail "relay exit code $rc after SIGTERM" ;;
esac

printf 'SMOKE PASS image=%s\n' "$image"
