#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# The repository NATS image is the monitored server; the pinned index is resolved per platform.
nats_index='ghcr.io/tektum/nats@sha256:2839bc0bad776f981009e63814639dc8b99f08f3dd658bf834891885decd7207'
label=verity.test=nats-top-$$
network="verity-nats-top-network-$$"
server="verity-nats-top-server-$$"
work=$(mktemp -d)

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -fv >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  docker logs "$server" >&2 2>/dev/null || true
  printf '%s\n' "$1" >&2
  exit 1
}

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/nats-top"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'CA bundle environment is missing'

docker run --rm --network none --read-only "$image" --version >"$work/version" 2>&1 ||
  fail 'nats-top --version failed'
grep -E "^nats-top v${expected_version}, commit [0-9a-f]{40}, built " "$work/version" >/dev/null ||
  fail "unexpected version output: $(cat "$work/version")"

if docker run --rm --network none --read-only "$image" --definitely-invalid \
  >"$work/invalid" 2>&1; then
  fail 'invalid argument unexpectedly succeeded'
fi
grep -F 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'invalid argument diagnostic is missing'

if docker run --rm --network none --read-only "$image" -s 127.0.0.1 -m 8222 -o - \
  >"$work/unreachable" 2>&1; then
  fail 'unreachable monitoring endpoint unexpectedly succeeded'
fi
grep -F 'nats-top: /varz smoke test failed' "$work/unreachable" >/dev/null ||
  fail 'unreachable monitoring endpoint diagnostic is missing'

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
nats_image=$(pull_child "$nats_index")

docker network create --label "$label" "$network" >/dev/null
docker run -d --label "$label" --name "$server" --network "$network" \
  --network-alias nats "$nats_image" -m 8222 -n verity-nats-top-smoke >/dev/null

top() {
  docker run --rm --label "$label" --network "$network" --read-only "$image" "$@"
}

attempts=0
until top -s nats -m 8222 -o - >"$work/snapshot" 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || fail "nats-top never read the server: $(cat "$work/snapshot")"
  sleep 1
done

grep -E '^NATS server version [0-9]+\.[0-9]+\.[0-9]+ \(uptime: ' "$work/snapshot" >/dev/null ||
  fail "snapshot is missing the server header: $(cat "$work/snapshot")"
grep -Fx 'Server: verity-nats-top-smoke' "$work/snapshot" >/dev/null ||
  fail "snapshot is missing the server name: $(cat "$work/snapshot")"
grep -E '^  ID: +N[A-Z0-9]{55}$' "$work/snapshot" >/dev/null ||
  fail "snapshot is missing the server ID: $(cat "$work/snapshot")"
grep -E '^Connections Polled: [0-9]+$' "$work/snapshot" >/dev/null ||
  fail "snapshot is missing the connections section: $(cat "$work/snapshot")"

top -s nats -m 8222 -o - -l , >"$work/delimited" 2>&1 ||
  fail "delimited snapshot failed: $(cat "$work/delimited")"
grep -E '^NATS server version,[0-9]+\.[0-9]+\.[0-9]+,\(uptime: ' "$work/delimited" >/dev/null ||
  fail "delimited snapshot is missing the server header: $(cat "$work/delimited")"

printf 'SMOKE PASS image=%s\n' "$image"
