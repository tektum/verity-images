#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)"$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
container="verity-coredns-test-$$"
config=$(mktemp)
invalid=$(mktemp)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -f "$config" "$invalid"
}
trap cleanup EXIT INT TERM

cat >"$config" <<'EOF'
.:53 {
  hosts {
    192.0.2.53 coredns.test
  }
}
EOF
cat >"$invalid" <<'EOF'
.:53 {
  definitely-not-a-plugin
}
EOF
chmod 644 "$config" "$invalid"

test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/coredns"]'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["-conf","/Corefile"]'
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532
docker run --rm --entrypoint /coredns "$image" -version | grep -Fq "CoreDNS-$expected_version"

if docker run --rm "$image" >/dev/null 2>&1; then
  printf '%s\n' 'missing Corefile unexpectedly succeeded' >&2
  exit 1
fi
if docker run --rm -v "$invalid:/Corefile:ro" "$image" >/dev/null 2>&1; then
  printf '%s\n' 'invalid Corefile unexpectedly succeeded' >&2
  exit 1
fi

docker run --name "$container" -d --read-only --user 65532 \
  -v "$config:/Corefile:ro" "$image" >/dev/null

i=0
until docker exec "$container" dig +short @127.0.0.1 coredns.test 2>/dev/null | grep -qx 192.0.2.53; do
  i=$((i + 1))
  if [ "$i" -ge 20 ]; then
    docker logs "$container" >&2 || true
    printf '%s\n' 'DNS response did not contain 192.0.2.53' >&2
    exit 1
  fi
  sleep 1
done

docker stop "$container" >/dev/null
test "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0
printf 'SMOKE PASS image=%s\n' "$image"
