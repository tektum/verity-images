#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
config="$here/../apko.yaml"
version=$(sed -n 's/^    - gostatsd=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
work=$(mktemp -d)
receiver=
name="gostatsd-smoke-$$"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  [ -z "$receiver" ] || kill "$receiver" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail 'could not read the pinned gostatsd version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/gostatsd"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

docker run --rm --network none "$image" --version >"$work/version" 2>&1 ||
  fail 'version failed'
grep -E "^Version: $version - Commit: [0-9a-f]{40} " "$work/version" >/dev/null ||
  fail "version does not report gostatsd $version: $(cat "$work/version")"

rc=0
docker run --rm --network none "$image" --definitely-invalid >"$work/invalid" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"

free_port() {
  python3 -c 'import socket, sys; s=socket.socket(socket.AF_INET, getattr(socket, sys.argv[1])); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])' "$1"
}

# A local TCP listener plays the Graphite backend; gostatsd receives statsd UDP
# packets from the host and flushes the aggregates to it.
graphite_port=$(free_port SOCK_STREAM)
statsd_port=$(free_port SOCK_DGRAM)
cat >"$work/graphite.py" <<'EOF'
import socket
import sys

server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", int(sys.argv[1])))
server.listen(5)
with open(sys.argv[2], "ab", 0) as out:
    while True:
        conn, _ = server.accept()
        while True:
            data = conn.recv(65536)
            if not data:
                break
            out.write(data)
EOF
: >"$work/graphite.out"
python3 "$work/graphite.py" "$graphite_port" "$work/graphite.out" &
receiver=$!

cat >"$work/gostatsd.toml" <<EOF
[graphite]
address = "127.0.0.1:$graphite_port"
mode = "tags"
EOF
chmod 0644 "$work/gostatsd.toml"

docker run -d --name "$name" --network host --read-only --cap-drop=ALL \
  -v "$work/gostatsd.toml:/etc/gostatsd/gostatsd.toml:ro" "$image" \
  --config-path /etc/gostatsd/gostatsd.toml --backends graphite \
  --metrics-addr "127.0.0.1:$statsd_port" --flush-interval 1s \
  --internal-namespace smoke_internal >/dev/null || fail 'server start failed'

send() {
  python3 -c 'import socket, sys; socket.socket(socket.AF_INET, socket.SOCK_DGRAM).sendto(sys.argv[2].encode(), ("127.0.0.1", int(sys.argv[1])))' "$statsd_port" "$1"
}

# Readiness is the backend log line; then send until the first flush lands.
ready=
for _ in $(seq 1 60); do
  if docker logs "$name" 2>&1 | grep -F 'Initialised backend' >/dev/null; then
    ready=1
    break
  fi
  sleep 0.5
done
test -n "$ready" || fail "server did not initialise the backend: $(docker logs "$name" 2>&1)"

received=
for _ in $(seq 1 30); do
  send "$(printf 'smoke.requests:3|c|#env:test\nsmoke.temperature:42|g\nsmoke.latency:250|ms\nsmoke.users:alice|s\nsmoke.users:bob|s')"
  sleep 1
  if grep -F 'stats.gauges.smoke.temperature' "$work/graphite.out" >/dev/null; then
    received=1
    break
  fi
done
test -n "$received" ||
  fail "no flushed metrics reached the graphite backend: $(docker logs "$name" 2>&1 | tail -n 20)"
sleep 2

grep -E '^stats\.counters\.smoke\.requests\.count;env=test;[^ ]* [1-9][0-9]* [0-9]+$' \
  "$work/graphite.out" >/dev/null || fail 'counter with its tag was not flushed'
grep -E '^stats\.gauges\.smoke\.temperature;[^ ]* 42\.0+ [0-9]+$' "$work/graphite.out" >/dev/null ||
  fail 'gauge value 42 was not flushed'
grep -E '^stats\.timers\.smoke\.latency\.upper;[^ ]* 250\.0+ [0-9]+$' "$work/graphite.out" >/dev/null ||
  fail 'timer upper bound 250 was not flushed'
grep -E '^stats\.timers\.smoke\.latency\.mean_90;' "$work/graphite.out" >/dev/null ||
  fail 'default 90th percentile timer aggregate was not flushed'
grep -E '^stats\.sets\.smoke\.users;[^ ]* 2(\.0+)? [0-9]+$' "$work/graphite.out" >/dev/null ||
  fail "set cardinality 2 was not flushed: $(grep smoke.users "$work/graphite.out" | head -n 3)"
grep -E 'smoke_internal\.' "$work/graphite.out" >/dev/null ||
  fail 'internal metrics were not flushed under the configured namespace'

# Malformed packets are dropped without stopping the server.
send 'this is not statsd'
sleep 2
test "$(docker inspect --format '{{.State.Running}}' "$name")" = true ||
  fail "server exited after a malformed packet: $(docker logs "$name" 2>&1 | tail -n 20)"

docker stop -t 10 "$name" >/dev/null || fail 'server did not stop on SIGTERM'
status=$(docker inspect --format '{{.State.ExitCode}}' "$name")
test "$status" = 0 || fail "server exited with status $status after SIGTERM"

echo 'SMOKE PASS'
