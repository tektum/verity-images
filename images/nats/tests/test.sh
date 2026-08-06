#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-nats-test-$$"
volume="verity-nats-data-$$"
config=$(mktemp)
pidfile=$(mktemp)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
  rm -f "$config" "$pidfile"
}
trap cleanup EXIT INT TERM

test "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532 || {
  printf '%s\n' 'image user is not 65532' >&2
  exit 1
}
test "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["nats-server"]' || {
  printf '%s\n' 'unexpected image entrypoint' >&2
  exit 1
}
docker volume create "$volume" >/dev/null

start_server() {
  docker run --name "$container" -d \
    -v "$volume:/data/nats" \
    -p 127.0.0.1::4222 -p 127.0.0.1::8222 \
    "$image" --jetstream --store_dir /data/nats --http_port 8222 \
    --pid /etc/nats/nats.pid >/dev/null
  nats_port=$(docker port "$container" 4222/tcp | awk -F: 'NR == 1 { print $2 }')
  http_port=$(docker port "$container" 8222/tcp | awk -F: 'NR == 1 { print $2 }')

  i=0
  until curl --fail --silent --connect-timeout 1 --max-time 2 \
    "http://127.0.0.1:$http_port/healthz" >/dev/null; do
    i=$((i + 1))
    [ "$i" -lt 20 ] || {
      docker logs "$container" >&2
      exit 1
    }
    sleep 1
  done
}

request() {
  request_subject=$1
  request_payload=$2
  reply="_INBOX.verity.$$"
  printf 'CONNECT {"verbose":false}\r\nSUB %s 1\r\nPUB %s %s %s\r\n%s\r\nPING\r\n' \
    "$reply" "$request_subject" "$reply" "${#request_payload}" "$request_payload" |
    curl --silent --connect-timeout 1 --max-time 2 \
      "telnet://127.0.0.1:$nats_port" || true
}

start_server
docker cp "$container:/etc/nats/nats.pid" "$pidfile" >/dev/null
test -s "$pidfile" || {
  printf '%s\n' 'NATS did not write its PID under /etc/nats' >&2
  exit 1
}

subject="verity.$$"
response=$(printf 'CONNECT {"verbose":false}\r\nSUB %s 1\r\nPUB %s 5\r\nworks\r\nPING\r\n' "$subject" "$subject" |
  curl --silent --connect-timeout 1 --max-time 2 \
    "telnet://127.0.0.1:$nats_port" || true)
printf '%s' "$response" | grep -q "MSG $subject 1 5" || {
  printf '%s\n' 'NATS pub/sub response missing message metadata' >&2
  exit 1
}
printf '%s' "$response" | grep -q works || {
  printf '%s\n' 'NATS pub/sub response missing payload' >&2
  exit 1
}
curl --fail --silent "http://127.0.0.1:$http_port/varz" | grep -q '"server_id"' || {
  printf '%s\n' 'NATS monitoring response missing server ID' >&2
  exit 1
}

created=$(request "\$JS.API.STREAM.CREATE.VERITY" \
  '{"name":"VERITY","subjects":["verity.persist"]}')
printf '%s' "$created" | grep -q '"name":"VERITY"' || {
  printf '%s\n' 'JetStream stream creation failed' >&2
  exit 1
}
stored=$(request verity.persist persist)
printf '%s' "$stored" | grep -q '"stream":"VERITY","seq":1' || {
  printf '%s\n' 'JetStream did not acknowledge the persisted message' >&2
  exit 1
}

docker rm -f "$container" >/dev/null
start_server
restored=$(request "\$JS.API.STREAM.MSG.GET.VERITY" '{"seq":1}')
printf '%s' "$restored" | grep -q '"data":"cGVyc2lzdA=="' || {
  printf '%s\n' 'JetStream message did not survive restart' >&2
  exit 1
}

printf '%s\n' 'this is not valid {' >"$config"
chmod 644 "$config"
if docker run --rm -v "$config:/etc/nats/invalid.conf:ro" "$image" \
  --config /etc/nats/invalid.conf >/dev/null 2>&1; then
  printf '%s\n' 'invalid config unexpectedly succeeded' >&2
  exit 1
fi

printf 'SMOKE PASS image=%s\n' "$image"
