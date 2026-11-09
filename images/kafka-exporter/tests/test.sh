#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
exporter="verity-kafka-exporter-$$"
tmp=$(mktemp -d)
broker_pid=

cleanup() {
  docker rm -f "$exporter" >/dev/null 2>&1 || true
  [ -z "$broker_pid" ] || kill "$broker_pid" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

version=$(awk -F'"' '$1 ~ /^  version:/ { print $2; exit }' "$here/../melange.yaml")
test -n "$version" || fail 'cannot read the package version from melange.yaml'

test "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532 ||
  fail 'image must run as UID 65532'
test "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/kafka_exporter"]' ||
  fail 'unexpected entrypoint'

docker run --rm "$image" --version >"$tmp/version" 2>&1 ||
  fail 'kafka_exporter --version failed'
grep -F "kafka_exporter, version $version " "$tmp/version" >/dev/null ||
  { cat "$tmp/version" >&2; fail "version output does not report $version"; }
revision=$(sed -n 's/.*revision: \([0-9a-f]\{40\}\)).*/\1/p' "$tmp/version")
test -n "$revision" || fail 'version output does not carry the source revision'

# An unknown flag must be rejected with a readable error, not ignored.
if docker run --rm "$image" --verity.no-such-flag >"$tmp/flag.log" 2>&1; then
  fail 'unknown flag unexpectedly succeeded'
fi
grep -F 'unknown long flag' "$tmp/flag.log" >/dev/null ||
  { cat "$tmp/flag.log" >&2; fail 'unknown flag error is not readable'; }

# An unreachable broker must stop the exporter with a readable error.
if docker run --rm --network none "$image" --kafka.server=127.0.0.1:9092 >"$tmp/nobroker.log" 2>&1; then
  fail 'exporter unexpectedly started without a reachable broker'
fi
grep -F 'Error Init Kafka Client' "$tmp/nobroker.log" >/dev/null ||
  { cat "$tmp/nobroker.log" >&2; fail 'unreachable broker error is not readable'; }

# Minimal Kafka broker: answers ApiVersions and Metadata with one broker and no topics.
cat >"$tmp/broker.py" <<'PY'
import socket, struct, sys, threading

host, port = sys.argv[1], int(sys.argv[2])

def s16(v): return struct.pack(">h", v)
def s32(v): return struct.pack(">i", v)
def string(v):
    b = v.encode()
    return s16(len(b)) + b
def array(items): return s32(len(items)) + b"".join(items)

def recv_exact(conn, n):
    data = b""
    while len(data) < n:
        chunk = conn.recv(n - len(data))
        if not chunk:
            raise EOFError
        data += chunk
    return data

def metadata(version):
    out = b""
    if version >= 3:
        out += s32(0)
    out += array([s32(1) + string(host) + s32(port) + (s16(-1) if version >= 1 else b"")])
    if version >= 2:
        out += s16(-1)
    if version >= 1:
        out += s32(1)
    out += array([])
    return out

def handle(conn):
    try:
        while True:
            size = struct.unpack(">i", recv_exact(conn, 4))[0]
            req = recv_exact(conn, size)
            key, version, corr = struct.unpack(">hhi", req[:8])
            if key == 3:
                body = metadata(version)
            elif key == 18:
                apis = [(3, 0, 5), (18, 0, 0)]
                body = s16(0) + array([s16(k) + s16(lo) + s16(hi) for k, lo, hi in apis])
            else:
                conn.close()
                return
            conn.sendall(s32(4 + len(body)) + s32(corr) + body)
    except (EOFError, OSError):
        pass

srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("0.0.0.0", port))
srv.listen(16)
while True:
    c, _ = srv.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
PY
broker_port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("", 0)); print(s.getsockname()[1])')
python3 "$tmp/broker.py" host.docker.internal "$broker_port" &
broker_pid=$!

docker run --name "$exporter" -d --read-only \
  --add-host host.docker.internal:host-gateway \
  -p 127.0.0.1::9308 \
  "$image" --kafka.server="host.docker.internal:$broker_port" >/dev/null
web_port=$(docker port "$exporter" 9308/tcp | awk -F: 'NR == 1 { print $2 }')
test -n "$web_port" || fail 'exporter port 9308 is not published'

attempts=0
until curl --fail --silent --connect-timeout 1 --max-time 5 \
  "http://127.0.0.1:$web_port/healthz" >"$tmp/healthz" 2>/dev/null; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || { docker logs "$exporter" >&2; fail 'exporter did not become ready'; }
  sleep 1
done
grep -Fx ok "$tmp/healthz" >/dev/null || fail '/healthz did not answer ok'

curl --fail --silent --max-time 5 "http://127.0.0.1:$web_port/" >"$tmp/landing" ||
  fail 'landing page request failed'
grep -F '<h1>Kafka Exporter</h1>' "$tmp/landing" >/dev/null || fail 'landing page content missing'

attempts=0
until curl --fail --silent --max-time 10 "http://127.0.0.1:$web_port/metrics" >"$tmp/metrics" 2>/dev/null &&
  grep -Fx 'kafka_brokers 1' "$tmp/metrics" >/dev/null; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 15 ] || { docker logs "$exporter" >&2; fail 'kafka_brokers 1 did not appear'; }
  sleep 1
done
grep -F "kafka_broker_info{address=\"host.docker.internal:$broker_port\",id=\"1\"} 1" "$tmp/metrics" >/dev/null ||
  fail 'kafka_broker_info missing for the broker'
grep -F "kafka_exporter_build_info{" "$tmp/metrics" | grep -F "revision=\"$revision\"" |
  grep -F "version=\"$version\"" >/dev/null ||
  fail 'kafka_exporter_build_info does not match --version'

# The exporter does not trap SIGTERM; it must still stop at once (143), not be killed (137).
docker stop --time 10 "$exporter" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$exporter")" = 143 ] ||
  fail 'exporter did not stop on SIGTERM'

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$version"
