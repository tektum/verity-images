#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image")
container="verity-cortex-test-$$"
tmp=$(mktemp -d)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 10001 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/cortex"]' ||
  fail 'unexpected entrypoint'
docker run --rm --platform "$platform" "$image" -version 2>&1 |
  grep -E '^Cortex, version [0-9]+\.[0-9]+\.[0-9]+ ' >/dev/null || fail 'unexpected version output'

# Negative: an unknown flag and a missing config file both exit non-zero.
if docker run --rm --platform "$platform" "$image" -no-such-flag >"$tmp/flag" 2>&1; then
  fail 'unknown flag unexpectedly succeeded'
fi
grep -F 'no-such-flag' "$tmp/flag" >/dev/null || fail 'unknown flag diagnostic is missing'
if docker run --rm --platform "$platform" "$image" -config.file=/definitely-missing.yaml \
  >"$tmp/missing" 2>&1; then
  fail 'missing config unexpectedly succeeded'
fi
grep -F 'definitely-missing.yaml' "$tmp/missing" >/dev/null || fail 'missing config diagnostic is missing'

cat >"$tmp/cortex.yaml" <<'EOF'
auth_enabled: false
server:
  http_listen_port: 9009
distributor:
  shard_by_all_labels: true
ingester:
  lifecycler:
    min_ready_duration: 0s
    final_sleep: 0s
    num_tokens: 16
    ring:
      kvstore:
        store: inmemory
      replication_factor: 1
blocks_storage:
  backend: filesystem
  filesystem:
    dir: /data/blocks
  tsdb:
    dir: /data/tsdb
  bucket_store:
    sync_dir: /data/tsdb-sync
compactor:
  data_dir: /data/compactor
  sharding_ring:
    kvstore:
      store: inmemory
store_gateway:
  sharding_ring:
    replication_factor: 1
    kvstore:
      store: inmemory
ruler_storage:
  backend: local
  local:
    directory: /data/rules
alertmanager_storage:
  backend: local
  local:
    path: /data/alerts
EOF
chmod 644 "$tmp/cortex.yaml"

docker run --platform "$platform" --name "$container" -d -p 127.0.0.1::9009 \
  -v "$tmp/cortex.yaml:/etc/cortex/cortex.yaml:ro" \
  "$image" -config.file=/etc/cortex/cortex.yaml -target=all >/dev/null
port=$(docker port "$container" 9009/tcp | awk -F: 'NR == 1 { print $2 }')
test -n "$port"

i=0
until [ "$(curl --silent --max-time 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/ready" 2>/dev/null || true)" = 200 ]; do
  [ "$(docker inspect -f '{{.State.Running}}' "$container")" = true ] || {
    docker logs "$container" >&2
    fail 'cortex exited before becoming ready'
  }
  i=$((i + 1))
  [ "$i" -lt 120 ] || {
    docker logs "$container" >&2
    fail 'cortex did not become ready'
  }
  sleep 1
done

# Push one sample through the Prometheus remote-write API (a snappy-framed
# protobuf WriteRequest built by hand, since the image has no client) and read
# it back through the query API.
python3 - "$port" <<'PY' || fail 'remote write and query round trip failed'
import json, struct, sys, time, urllib.request

port = sys.argv[1]


def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def field(num, wire, payload):
    return varint((num << 3) | wire) + payload


def length_delimited(num, data):
    return field(num, 2, varint(len(data)) + data)


def label(name, value):
    return length_delimited(1, length_delimited(1, name.encode()) + length_delimited(2, value.encode()))


now_ms = int(time.time() * 1000)
sample = field(1, 1, struct.pack('<d', 42.0)) + field(2, 0, varint(now_ms))
series = label('__name__', 'verity_test_metric') + label('job', 'verity') + length_delimited(2, sample)
write_request = length_delimited(1, series)
# Snappy block format: uncompressed length, then one literal element.
assert len(write_request) < 60
body = varint(len(write_request)) + bytes([(len(write_request) - 1) << 2]) + write_request

req = urllib.request.Request(
    f'http://127.0.0.1:{port}/api/v1/push',
    data=body,
    headers={
        'Content-Encoding': 'snappy',
        'Content-Type': 'application/x-protobuf',
        'X-Prometheus-Remote-Write-Version': '0.1.0',
    },
)
with urllib.request.urlopen(req, timeout=10) as resp:
    assert resp.status in (200, 204), resp.status

deadline = time.time() + 60
last = None
while time.time() < deadline:
    url = f'http://127.0.0.1:{port}/prometheus/api/v1/query?query=verity_test_metric'
    with urllib.request.urlopen(url, timeout=10) as resp:
        last = json.load(resp)
    result = last.get('data', {}).get('result', [])
    if last.get('status') == 'success' and result and result[0]['value'][1] == '42':
        sys.exit(0)
    time.sleep(1)
sys.exit(f'sample was not queryable: {last}')
PY

docker stop --time 30 "$container" >/dev/null
case $(docker inspect --format '{{.State.ExitCode}}' "$container") in
  0|143) ;;
  *) fail 'cortex did not stop cleanly on SIGTERM' ;;
esac

printf 'SMOKE PASS image=%s\n' "$image"
