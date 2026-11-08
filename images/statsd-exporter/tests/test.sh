#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
flavor=${2:-plain}
exporter="verity-statsd-exporter-$$"
tmp=$(mktemp -d)

cleanup() {
  docker rm -f "$exporter" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

wait_metrics() {
  # $1 container, $2 host port, $3 output file, $4 required line (fixed, whole line)
  attempts=0
  until curl --fail --silent --connect-timeout 1 --max-time 5 \
    "http://127.0.0.1:$2/metrics" >"$3" 2>/dev/null && grep -Fx "$4" "$3" >/dev/null; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 30 ] || {
      docker logs "$1" >&2
      fail "metrics did not contain: $4"
    }
    sleep 1
  done
}

test "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532 ||
  fail 'image must run as UID 65532'
test "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/statsd_exporter"]' ||
  fail 'unexpected entrypoint'
docker run --rm "$image" --version 2>&1 | grep -E 'statsd_exporter, version 0\.' >/dev/null ||
  fail 'unexpected exporter version'

created=$(docker create "$image")
docker cp "$created:/usr/bin/statsd_exporter" "$tmp/statsd_exporter"
docker rm "$created" >/dev/null
if [ "$flavor" = fips ]; then
  go version -m "$tmp/statsd_exporter" | grep -q 'GOFIPS140=v1.0.0' ||
    fail 'fips flavor must be built with GOFIPS140=v1.0.0'
elif go version -m "$tmp/statsd_exporter" | grep -q 'GOFIPS140='; then
  fail 'plain flavor must not set GOFIPS140'
fi

cat >"$tmp/mapping.yml" <<'EOF'
mappings:
  - match: "hits.*.*"
    name: "verity_hits_total"
    labels:
      endpoint: "$1"
      code: "$2"
EOF
chmod 644 "$tmp/mapping.yml"

# A malformed mapping file must stop the exporter instead of being ignored.
printf '%s\n' 'mappings: [this is not valid' >"$tmp/invalid.yml"
chmod 644 "$tmp/invalid.yml"
if docker run --rm -v "$tmp/invalid.yml:/tmp/mapping.yml:ro" "$image" \
  --statsd.mapping-config=/tmp/mapping.yml >"$tmp/invalid.log" 2>&1; then
  fail 'invalid mapping config unexpectedly succeeded'
fi

docker run --name "$exporter" -d --read-only \
  -v "$tmp/mapping.yml:/tmp/mapping.yml:ro" \
  -p 127.0.0.1::9102 -p 127.0.0.1::9125/udp \
  "$image" --statsd.mapping-config=/tmp/mapping.yml >/dev/null
web_port=$(docker port "$exporter" 9102/tcp | awk -F: 'NR == 1 { print $2 }')
udp_port=$(docker port "$exporter" 9125/udp | awk -F: 'NR == 1 { print $2 }')
test -n "$web_port" && test -n "$udp_port"

attempts=0
until curl --fail --silent --connect-timeout 1 --max-time 5 \
  "http://127.0.0.1:$web_port/metrics" >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || { docker logs "$exporter" >&2; fail 'exporter did not become ready'; }
  sleep 1
done

# UDP is lossy; resend until the mapped counter appears, then require the exact
# accumulated value for the labels derived from the mapping.
attempts=0
until python3 - "$udp_port" <<'PY'
import socket
import sys

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.sendto(b"hits.api.200:3|c", ("127.0.0.1", int(sys.argv[1])))
PY
  sleep 1
  curl --fail --silent --max-time 5 "http://127.0.0.1:$web_port/metrics" >"$tmp/metrics" &&
    grep -E '^verity_hits_total\{code="200",endpoint="api"\} [0-9]+$' "$tmp/metrics" >/dev/null; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 15 ] || { docker logs "$exporter" >&2; fail 'mapped counter did not appear'; }
done
# Each resend adds 3, so the value must be a positive multiple of 3.
value=$(sed -n 's/^verity_hits_total{code="200",endpoint="api"} //p' "$tmp/metrics")
[ "$value" -gt 0 ] && [ $((value % 3)) -eq 0 ] ||
  fail "mapped counter value $value is not a multiple of 3"
grep -F 'statsd_exporter_build_info{' "$tmp/metrics" >/dev/null ||
  fail 'statsd_exporter_build_info missing'

docker stop "$exporter" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$exporter")" = 0 ] ||
  fail 'exporter did not stop cleanly on SIGTERM'

printf 'SMOKE PASS image=%s flavor=%s\n' "$image" "$flavor"
