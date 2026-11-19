#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
nats_index='ghcr.io/tektum/nats@sha256:2839bc0bad776f981009e63814639dc8b99f08f3dd658bf834891885decd7207'
python_index=ghcr.io/tektum/python@sha256:d059268a2e4f0ef0cc82bb50c847e69e16e174736758013a153cb36311fa6dd6
nats="verity-wasmcloud-nats-$$"
host="verity-wasmcloud-host-$$"
host_id="verity-smoke-$$"
fixture=$(mktemp -d)

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$host" "$nats" >/dev/null 2>&1 || true
  rm -rf "$fixture"
}
trap cleanup EXIT INT TERM

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] || fail 'image user is not 65532'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/wash"]' ] ||
  fail 'unexpected image entrypoint'
[ "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/wasmcloud ] ||
  fail 'unexpected working directory'

version=$(docker run --rm --cpus 2 "$image" --version)
case "$version" in
  'wash '[0-9]*.[0-9]*.[0-9]*) version=${version#wash } ;;
  *) fail "unexpected version output: $version" ;;
esac

if docker run --rm --cpus 2 "$image" --no-such-flag >"$fixture/flag.out" 2>&1; then
  fail 'unknown flag unexpectedly succeeded'
fi
grep -q "unexpected argument '--no-such-flag'" "$fixture/flag.out" || {
  cat "$fixture/flag.out" >&2
  fail 'unknown flag did not report a readable error'
}

# Negative: a host that cannot reach its control plane exits non-zero.
if docker run --rm --cpus 2 --network none "$image" host \
  --scheduler-nats-url nats://127.0.0.1:4222 --nats-connect-timeout 3s >"$fixture/nonats.out" 2>&1; then
  fail 'host without NATS unexpectedly succeeded'
fi
grep -q 'failed to connect to NATS' "$fixture/nonats.out" || {
  cat "$fixture/nonats.out" >&2
  fail 'host without NATS did not report a readable error'
}

docker run --name "$nats" --cpus 2 -d "$nats_index" >/dev/null
docker run --name "$host" --cpus 2 -d --network "container:$nats" "$image" host \
  --host-id "$host_id" --scheduler-nats-url nats://127.0.0.1:4222 \
  --http-addr 127.0.0.1:8000 >/dev/null

i=0
until docker logs "$host" 2>&1 | grep -q "Host started host_id=\"$host_id\""; do
  [ "$(docker inspect --format '{{.State.Running}}' "$host")" = true ] || {
    docker logs "$host" >&2
    fail 'host exited before starting'
  }
  i=$((i + 1))
  [ "$i" -lt 60 ] || {
    docker logs "$host" >&2
    fail 'host did not start'
  }
  sleep 1
done
docker logs "$host" 2>&1 | grep -q "Host started host_id=\"$host_id\".* version=\"$version\"" ||
  fail 'host start log does not report the image version'

cat >"$fixture/probe.py" <<'EOF'
import json
import socket
import sys
import time
import urllib.error
import urllib.request

host_id, version = sys.argv[1], sys.argv[2]

try:
    urllib.request.urlopen("http://127.0.0.1:8000/", timeout=5)
    sys.exit("HTTP router served a request without any deployed workload")
except urllib.error.HTTPError as error:
    if error.code != 404:
        sys.exit("unexpected HTTP status from the host router: %d" % error.code)
print("http 404")

subject = "runtime.operator.heartbeat." + host_id
sock = socket.create_connection(("127.0.0.1", 4222), timeout=5)
sock.recv(4096)
sock.sendall(('CONNECT {"verbose":false}\r\nSUB %s 1\r\nPING\r\n' % subject).encode())
buffer = b""
deadline = time.time() + 60
while time.time() < deadline:
    marker = buffer.find(b"MSG " + subject.encode())
    if marker >= 0:
        header_end = buffer.find(b"\r\n", marker)
        if header_end >= 0:
            size = int(buffer[marker:header_end].split()[-1])
            body = buffer[header_end + 2:header_end + 2 + size]
            if len(body) == size:
                heartbeat = json.loads(body)
                if heartbeat.get("id") != host_id:
                    sys.exit("heartbeat names another host: %r" % heartbeat.get("id"))
                if heartbeat.get("version") != version:
                    sys.exit("heartbeat reports version %r" % heartbeat.get("version"))
                print("heartbeat", heartbeat["id"], heartbeat["version"])
                sys.exit(0)
    try:
        chunk = sock.recv(65536)
    except socket.timeout:
        continue
    if not chunk:
        break
    buffer += chunk
sys.exit("no heartbeat on " + subject)
EOF
chmod 0644 "$fixture/probe.py"
docker run --rm --cpus 2 --network "container:$nats" -v "$fixture/probe.py:/probe.py:ro" \
  "$python_index" /probe.py "$host_id" "$version" >"$fixture/probe.out" 2>&1 || {
  cat "$fixture/probe.out" >&2
  docker logs "$host" >&2
  fail 'host control plane probe failed'
}
grep -qx "heartbeat $host_id $version" "$fixture/probe.out" || fail 'host heartbeat was not observed'

docker exec "$host" /usr/bin/wash --version >/dev/null 2>&1 || fail 'wash is not runnable inside the host container'
docker kill --signal TERM "$host" >/dev/null
i=0
while [ "$(docker inspect --format '{{.State.Running}}' "$host")" = true ]; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail 'host did not stop after SIGTERM'
  sleep 1
done
status=$(docker inspect --format '{{.State.ExitCode}}' "$host")
[ "$status" -eq 0 ] || {
  docker logs "$host" >&2
  fail "host exited with status $status after SIGTERM"
}
docker logs "$host" 2>&1 | grep -q 'Stopping host' || fail 'host did not log a graceful stop'

printf 'wasmcloud wash %s smoke test passed\n' "$version"
