#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-zipkin-test-$$"
work=$(mktemp -d)

fail() {
  printf '%s\n' "$1" >&2
  docker logs "$container" >&2 2>&1 || true
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /zipkin ] || fail 'unexpected OCI working directory'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' "$image")" = '["/usr/local/bin/start-zipkin"] null' ] ||
  fail 'unexpected OCI command'

docker run --name "$container" -d -p 127.0.0.1::9411 -p 127.0.0.1::9410 -e COLLECTOR_SCRIBE_ENABLED=true "$image" >/dev/null
port=$(docker port "$container" 9411/tcp | awk -F: 'NR == 1 { print $NF }')
[ -n "$port" ] || fail 'no published port'
base="http://127.0.0.1:$port"
scribe_port=$(docker port "$container" 9410/tcp | awk -F: 'NR == 1 { print $NF }')
[ -n "$scribe_port" ] || fail 'no published scribe port'

i=0
until health=$(curl --fail --silent --connect-timeout 1 --max-time 10 "$base/health"); do
  i=$((i + 1))
  [ "$i" -lt 120 ] || fail 'zipkin never became ready on :9411'
  sleep 1
done
printf '%s\n' "$health" | grep -Eq '"status" *: *"UP"' || fail "unexpected /health response: $health"

trace_id=463ac35c9f6413ad48485a3953bb6124
now_us=$(($(date +%s) * 1000000))
cat > "$work/spans.json" <<EOF
[
  {"traceId":"$trace_id","id":"a2fb4a1d1a96d312","name":"verity-root","kind":"SERVER","timestamp":$now_us,"duration":2000,
   "localEndpoint":{"serviceName":"verity-frontend"},"tags":{"http.method":"GET"}},
  {"traceId":"$trace_id","parentId":"a2fb4a1d1a96d312","id":"b3fc5b2e2ba7e423","name":"verity-child","kind":"CLIENT","timestamp":$now_us,"duration":1000,
   "localEndpoint":{"serviceName":"verity-frontend"},"remoteEndpoint":{"serviceName":"verity-backend"}}
]
EOF
status=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 10 \
  -X POST -H 'Content-Type: application/json' --data-binary "@$work/spans.json" "$base/api/v2/spans")
[ "$status" = 202 ] || fail "span batch POST returned $status, want 202"

i=0
until curl --fail --silent --max-time 10 "$base/api/v2/trace/$trace_id" > "$work/trace.json" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail 'posted trace was never readable via /api/v2/trace'
  sleep 1
done
[ "$(grep -o '"traceId"' "$work/trace.json" | wc -l)" = 2 ] || fail "trace did not contain both spans: $(cat "$work/trace.json")"
grep -Fq '"name":"verity-root"' "$work/trace.json" || fail 'root span missing from stored trace'
grep -Fq '"name":"verity-child"' "$work/trace.json" || fail 'child span missing from stored trace'
grep -Fq '"parentId":"a2fb4a1d1a96d312"' "$work/trace.json" || fail 'span parent link was not preserved'

services=$(curl --fail --silent --max-time 10 "$base/api/v2/services") || fail 'GET /api/v2/services failed'
printf '%s\n' "$services" | grep -Fq 'verity-frontend' || fail "service not indexed: $services"
remote=$(curl --fail --silent --max-time 10 "$base/api/v2/remoteServices?serviceName=verity-frontend") ||
  fail 'GET /api/v2/remoteServices failed'
printf '%s\n' "$remote" | grep -Fq 'verity-backend' || fail "remote service not indexed: $remote"

# The scribe collector speaks framed Thrift over TCP, which exercises libthrift end to end: send one
# v1 Thrift span in a Scribe Log call, expect ResultCode.OK, then read it back as a v2 span.
cat > "$work/scribe.py" <<'PY'
import base64, socket, struct, sys, time

port = int(sys.argv[1])
trace_id = int(sys.argv[2], 16)
now_us = int(time.time() * 1_000_000)


def i64(n):
    return struct.pack(">q", n if n < 1 << 63 else n - (1 << 64))


def string(s):
    b = s.encode()
    return struct.pack(">i", len(b)) + b


def field(ttype, fid, body):
    return struct.pack(">bh", ttype, fid) + body


endpoint = (
    field(8, 1, struct.pack(">i", 0x7F000001))
    + field(6, 2, struct.pack(">h", 8080))
    + field(11, 3, string("verity-scribe"))
    + b"\x00"
)


def annotation(ts, value):
    return field(10, 1, i64(ts)) + field(11, 2, string(value)) + field(12, 3, endpoint) + b"\x00"


span = (
    field(10, 1, i64(trace_id))
    + field(11, 3, string("scribe-span"))
    + field(10, 4, i64(0x2))
    + field(15, 6, struct.pack(">bi", 12, 2) + annotation(now_us, "sr") + annotation(now_us + 1000, "ss"))
    + field(15, 8, struct.pack(">bi", 12, 0))
    + b"\x00"
)
entry = field(11, 1, string("zipkin")) + field(11, 2, string(base64.b64encode(span).decode())) + b"\x00"
args = field(15, 1, struct.pack(">bi", 12, 1) + entry) + b"\x00"
message = struct.pack(">I", 0x80010001) + string("Log") + struct.pack(">i", 0) + args
frame = struct.pack(">i", len(message)) + message

with socket.create_connection(("127.0.0.1", port), timeout=10) as s:
    s.sendall(frame)
    header = s.recv(4)
    (length,) = struct.unpack(">i", header)
    body = b""
    while len(body) < length:
        chunk = s.recv(length - len(body))
        if not chunk:
            break
        body += chunk

if body[:4] != struct.pack(">I", 0x80010002) or b"Log" not in body[:12]:
    sys.exit("unexpected scribe reply: %r" % body)
# Result struct: field 0 (i32) holds the ResultCode, 0 is OK; the struct ends with a stop byte.
if not body.endswith(bytes.fromhex("0800000000000000")):
    sys.exit("scribe did not report ResultCode.OK: %r" % body)
print("scribe OK")
PY
python3 "$work/scribe.py" "$scribe_port" 1111111111111111 > "$work/scribe.out" 2>&1 || {
  cat "$work/scribe.out" >&2
  fail 'scribe Log call failed'
}
i=0
until curl --fail --silent --max-time 10 "$base/api/v2/trace/1111111111111111" > "$work/scribe-trace.json" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail 'span sent through the scribe collector was never readable'
  sleep 1
done
grep -Fq '"name":"scribe-span"' "$work/scribe-trace.json" || fail "scribe span missing: $(cat "$work/scribe-trace.json")"
grep -Fq '"serviceName":"verity-scribe"' "$work/scribe-trace.json" || fail 'scribe span lost its endpoint'

status=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 10 "$base/api/v2/trace/ffffffffffffffff")
[ "$status" = 404 ] || fail "unknown trace returned $status, want 404"

status=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 10 \
  -X POST -H 'Content-Type: application/json' --data-binary '{not json' "$base/api/v2/spans")
[ "$status" = 400 ] || fail "malformed span batch returned $status, want 400"

curl --fail --silent --location --max-time 10 "$base/zipkin/" > "$work/ui.html" || fail 'GET /zipkin/ failed'
grep -qi '<html' "$work/ui.html" || fail '/zipkin/ did not return the UI page'

# GHSA-794x-8x6x-qpfc (CVE-2025-53602) covers a /heapdump endpoint through 3.5.1; 3.6.x must not serve one.
for path in /actuator/heapdump /heapdump; do
  status=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 10 "$base$path")
  [ "$status" = 404 ] || fail "$path returned $status, want 404"
done

docker stop "$container" >/dev/null
# The JVM exits with 128 + SIGTERM after running its shutdown hooks.
[ "$(docker inspect -f '{{.State.ExitCode}}' "$container")" = 143 ] || fail 'unexpected exit status after SIGTERM'

# Negative: an unusable storage configuration must stop the server with a readable error.
if output=$(docker run --rm --network none -e STORAGE_TYPE=verity-invalid "$image" 2>&1); then
  fail 'invalid STORAGE_TYPE unexpectedly started'
fi
# Spring reports an unknown storage type as a missing StorageComponent bean.
printf '%s\n' "$output" | grep -Fq 'APPLICATION FAILED TO START' || {
  printf '%s\n' "$output" >&2
  fail 'invalid STORAGE_TYPE did not produce a startup failure report'
}
printf '%s\n' "$output" | grep -Fq 'zipkin2.storage.StorageComponent' || {
  printf '%s\n' "$output" >&2
  fail 'invalid STORAGE_TYPE error did not name the missing storage component'
}

printf 'SMOKE PASS\n'
