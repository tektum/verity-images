#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-mimir-test-$$"
volume="verity-mimir-data-$$"
tmp=$(mktemp -d)

fail() {
  docker logs "$container" >&2 2>&1 || true
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 10001 ] \
  || fail 'image user is not 10001'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/mimir"]' ] \
  || fail 'unexpected image entrypoint'
docker run --rm "$image" -version 2>&1 | grep -F 'version 3.2.' >/dev/null \
  || fail 'mimir version check failed'

cat >"$tmp/config.yaml" <<'YAML'
target: all
multitenancy_enabled: false
usage_stats:
  enabled: false
server:
  http_listen_port: 8080
  grpc_listen_port: 9095
  log_level: warn
blocks_storage:
  backend: filesystem
  filesystem:
    dir: /data/blocks
  bucket_store:
    sync_dir: /data/tsdb-sync
  tsdb:
    dir: /data/tsdb
compactor:
  data_dir: /data/compactor
  sharding_ring:
    kvstore:
      store: inmemory
distributor:
  ring:
    instance_addr: 127.0.0.1
    kvstore:
      store: inmemory
ingester:
  ring:
    instance_addr: 127.0.0.1
    replication_factor: 1
    kvstore:
      store: inmemory
store_gateway:
  sharding_ring:
    replication_factor: 1
    kvstore:
      store: inmemory
ruler_storage:
  backend: filesystem
  filesystem:
    dir: /data/rules
YAML
chmod 644 "$tmp/config.yaml"

docker volume create "$volume" >/dev/null
docker run --name "$container" -d --read-only \
  -v "$volume:/data" -v "$tmp/config.yaml:/tmp/mimir.yaml:ro" \
  -p 127.0.0.1::8080 \
  "$image" -config.file=/tmp/mimir.yaml >/dev/null
http=$(docker port "$container" 8080/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$http" ] || fail 'mimir port was not published'

attempt=0
until response=$(curl --fail --silent --connect-timeout 1 --max-time 5 "http://127.0.0.1:$http/ready"); do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 120 ] || fail 'mimir did not become ready'
  sleep 1
done
printf '%s' "$response" | grep -F ready >/dev/null || fail 'mimir readiness response was unexpected'

# Remote-write one sample with a hand-built protobuf WriteRequest in a
# literal-only snappy block, then read it back through the query API.
python3 - "$tmp/write.bin" <<'PY'
import sys, time

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
    return varint(num << 3 | wire) + payload

def ld(num, data):
    return field(num, 2, varint(len(data)) + data)

def label(name, value):
    return ld(1, name.encode()) + ld(2, value.encode())

import struct
sample = field(1, 1, struct.pack('<d', 42.0)) + field(2, 0, varint(int(time.time() * 1000)))
series = ld(1, label('__name__', 'verity_smoke_metric')) + ld(1, label('job', 'verity')) + ld(2, sample)
raw = ld(1, series)

block = bytearray(varint(len(raw)))
pos = 0
while pos < len(raw):
    chunk = raw[pos:pos + 60]
    block.append((len(chunk) - 1) << 2)
    block += chunk
    pos += len(chunk)
open(sys.argv[1], 'wb').write(bytes(block))
PY
curl --fail --silent --show-error -X POST "http://127.0.0.1:$http/api/v1/push" \
  -H 'Content-Type: application/x-protobuf' -H 'Content-Encoding: snappy' \
  -H 'X-Prometheus-Remote-Write-Version: 0.1.0' --data-binary "@$tmp/write.bin" >/dev/null \
  || fail 'remote write sample was not accepted'

attempt=0
until curl --fail --silent --get "http://127.0.0.1:$http/prometheus/api/v1/query" \
  --data-urlencode 'query=verity_smoke_metric{job="verity"}' | grep -F '"42"' >/dev/null; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 30 ] || fail 'written sample was not queryable'
  sleep 1
done

docker stop --time 60 "$container" >/dev/null
code=$(docker inspect --format '{{.State.ExitCode}}' "$container")
[ "$code" = 0 ] || fail "mimir did not stop cleanly (exit $code)"

printf '%s\n' 'not: [valid' >"$tmp/invalid.yaml"
chmod 644 "$tmp/invalid.yaml"
if invalid=$(docker run --rm -v "$tmp/invalid.yaml:/tmp/invalid.yaml:ro" \
  "$image" -config.file=/tmp/invalid.yaml 2>&1); then
  fail 'invalid configuration unexpectedly succeeded'
fi
printf '%s' "$invalid" | grep -Ei 'yaml|parse|config' >/dev/null \
  || fail 'invalid configuration did not return a readable error'

printf 'SMOKE PASS image=%s\n' "$image"
