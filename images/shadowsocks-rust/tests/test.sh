#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
recipe="$(dirname "$0")/../melange.yaml"
version=$(sed -n 's/^  version: "\([0-9.]*\)".*$/\1/p' "$recipe")
label="verity-test=shadowsocks-rust-$$"
network="verity-shadowsocks-rust-$$"
prefix="verity-ss-$$"
work=$(mktemp -d)
python_image='docker.io/library/python@sha256:9ef1a599f863231c3d91e941389bfdc4a2d6070557243d54df1a4e57015b960e'
curl_image='docker.io/curlimages/curl@sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b'

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker network ls -q --filter "label=$label" | xargs -r docker network rm >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  for c in $(docker ps -aq --filter "label=$label"); do
    docker logs "$c" >&2 2>&1 || true
  done
  exit 1
}

[ -n "$version" ] || fail 'could not read the recipe version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/ssserver"]' || fail 'unexpected entrypoint'

hardened() {
  docker run --label "$label" --read-only --cap-drop ALL --security-opt no-new-privileges "$@"
}

# stdout only: docker may print a platform mismatch warning on stderr for emulated arm64 runs.
for bin in ssserver sslocal ssmanager ssservice; do
  out=$(hardened --rm --network none --entrypoint "/usr/bin/$bin" "$image" --version) ||
    fail "$bin --version failed"
  test "$out" = "shadowsocks $version" || fail "$bin does not report $version: $out"
done
out=$(hardened --rm --network none --entrypoint /usr/bin/ssurl "$image" --version) ||
  fail 'ssurl --version failed'
test "$out" = "ssurl $version" || fail "ssurl does not report $version: $out"

# Negative: an unknown flag is rejected.
if hardened --rm --network none "$image" --definitely-not-a-flag >"$work/flag.log" 2>&1; then
  fail 'unknown flag was accepted'
fi
grep -q "unexpected argument '--definitely-not-a-flag'" "$work/flag.log" ||
  fail "unexpected unknown-flag error: $(cat "$work/flag.log")"

# Keys come from the image itself; a 2022 cipher needs a 32-byte base64 key.
genkey() {
  hardened --rm --network none --entrypoint /usr/bin/ssservice "$image" \
    genkey -m 2022-blake3-aes-256-gcm
}
key=$(genkey) || fail 'genkey failed'
wrong_key=$(genkey) || fail 'genkey failed'
[ "$(printf '%s' "$key" | base64 -d | wc -c)" -eq 32 ] || fail "genkey returned a bad key: $key"
[ "$key" != "$wrong_key" ] || fail 'genkey returned the same key twice'

docker network create --label "$label" "$network" >/dev/null

mkdir -p "$work/www"
body="verity shadowsocks smoke $$"
printf '%s\n' "$body" >"$work/www/index.txt"
chmod -R a+rX "$work/www"
docker run -d --name "$prefix-web" --label "$label" --network "$network" \
  --network-alias web --read-only --cap-drop ALL --security-opt no-new-privileges \
  --user 65534:65534 -v "$work/www:/srv:ro" "$python_image" \
  python3 -m http.server 8000 --bind 0.0.0.0 --directory /srv >/dev/null

wait_log() {
  container=$1
  pattern=$2
  i=0
  until docker logs "$container" 2>&1 | grep -q "$pattern"; do
    i=$((i + 1))
    [ "$i" -le 60 ] || fail "$container did not log '$pattern'"
    [ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ] ||
      fail "$container exited before readiness"
    sleep 1
  done
}

start_pair() {
  # $1 suffix, $2 method, $3 server key, $4 client key
  hardened -d --name "$prefix-server-$1" --network "$network" --network-alias "server-$1" \
    "$image" -s 0.0.0.0:8388 -m "$2" -k "$3" >/dev/null
  hardened -d --name "$prefix-local-$1" --network "$network" --network-alias "local-$1" \
    --entrypoint /usr/bin/sslocal "$image" \
    -b 0.0.0.0:1080 -s "server-$1:8388" -m "$2" -k "$4" >/dev/null
  wait_log "$prefix-server-$1" 'listening on'
  wait_log "$prefix-local-$1" 'listening on'
}

fetch() {
  docker run --rm --label "$label" --network "$network" "$curl_image" \
    -sS --fail --max-time 15 --socks5-hostname "local-$1:1080" http://web:8000/index.txt
}

# The web server is reachable directly before testing through the proxy.
i=0
until docker run --rm --label "$label" --network "$network" "$curl_image" \
  -sS --fail --max-time 5 http://web:8000/index.txt >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -le 30 ] || fail 'web fixture did not become ready'
  sleep 1
done

start_pair aead2022 2022-blake3-aes-256-gcm "$key" "$key"
out=$(fetch aead2022) || fail 'SOCKS5 fetch through the 2022-blake3-aes-256-gcm tunnel failed'
test "$out" = "$body" || fail "unexpected body through the 2022 tunnel: $out"

password="verity-smoke-$$"
start_pair aead aes-256-gcm "$password" "$password"
out=$(fetch aead) || fail 'SOCKS5 fetch through the aes-256-gcm tunnel failed'
test "$out" = "$body" || fail "unexpected body through the aes-256-gcm tunnel: $out"

# Negative: a client with the wrong key or password gets no body, and the
# server reports the failed handshake instead of relaying.
start_pair wrongkey 2022-blake3-aes-256-gcm "$key" "$wrong_key"
if out=$(fetch wrongkey 2>"$work/wrongkey.log"); then
  fail "fetch succeeded with the wrong 2022 key: $out"
fi
wait_log "$prefix-server-wrongkey" 'tcp handshake failed'
start_pair wrongpass aes-256-gcm "$password" "wrong-$password"
if out=$(fetch wrongpass 2>"$work/wrongpass.log"); then
  fail "fetch succeeded with the wrong password: $out"
fi
wait_log "$prefix-server-wrongpass" 'tcp handshake failed'
for pair in aead2022 aead; do
  if docker logs "$prefix-server-$pair" 2>&1 | grep -q 'tcp handshake failed'; then
    fail "server-$pair reported a failed handshake for the correct key"
  fi
done

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$version"
