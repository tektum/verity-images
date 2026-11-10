#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
boot=verity-tailscale-boot-$$
daemon=verity-tailscale-daemon-$$

cleanup() {
  docker rm -f "$boot" "$daemon" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

# Poll the LocalAPI over the daemon socket until the backend reaches NeedsLogin.
wait_needs_login() {
  container=$1
  socket=$2
  state=
  attempt=0
  while [ "$attempt" -lt 30 ]; do
    state=$(docker exec "$container" tailscale --socket "$socket" status --json 2>/dev/null \
      | sed -n 's/^[[:space:]]*"BackendState": "\([A-Za-z]*\)",*$/\1/p') || true
    [ "$state" != NeedsLogin ] || return 0
    attempt=$((attempt + 1))
    sleep 1
  done
  docker logs "$container" >&2 || true
  fail "$container: BackendState is '$state', want NeedsLogin"
}

user=$(docker image inspect -f '{{.Config.User}}' "$image")
test "$user" = 65532 || fail "image user is $user, want 65532"

version=$(docker run --rm --entrypoint /usr/bin/tailscale "$image" version)
case "$version" in
  1.104.*) ;;
  *) fail "unexpected tailscale version output: $version" ;;
esac

# Default entrypoint: containerboot starts tailscaled in userspace networking mode
# without any capability or tun device, and waits for login with no auth key.
docker run -d --name "$boot" --network none -e TS_USERSPACE=true "$image" >/dev/null
wait_needs_login "$boot" /tmp/tailscaled.sock

# tailscaled directly, as non-root, userspace networking, in-memory state.
docker run -d --name "$daemon" --network none --entrypoint /usr/bin/tailscaled "$image" \
  --tun=userspace-networking --state=mem: --socket=/tmp/ts.sock >/dev/null
wait_needs_login "$daemon" /tmp/ts.sock

if docker exec "$daemon" tailscale --socket /tmp/ts.sock ip -4 >/dev/null 2>&1; then
  fail 'logged-out node unexpectedly reported a tailnet address'
fi

printf 'SMOKE PASS image=%s\n' "$image"
