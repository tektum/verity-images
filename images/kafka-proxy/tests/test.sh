#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
recipe="$(dirname "$0")/../melange.yaml"
version=$(sed -n 's/^  version: "\([0-9.]*\)".*$/\1/p' "$recipe")
# Catalog Kafka (KRaft) image, pinned by index digest, provides the broker and client tools.
kafka=ghcr.io/tektum/kafka@sha256:186c1aea3c1ceb0e556e99e2be42cbf898787f63a46f66c9d617abd136716baf
label="verity-test=kafka-proxy-$$"
backend="verity-kafka-proxy-back-$$"
frontend="verity-kafka-proxy-front-$$"
broker="verity-kafka-proxy-broker-$$"
proxy="verity-kafka-proxy-proxy-$$"
absent="verity-kafka-proxy-absent-$$"
unmapped="verity-kafka-proxy-unmapped-$$"
work=$(mktemp -d)

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker network rm "$frontend" "$backend" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

dump() {
  for name in "$@"; do
    printf '== logs: %s\n' "$name" >&2
    docker logs "$name" >&2 2>&1 || true
  done
}

[ -n "$version" ] || fail 'could not read the recipe version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/kafka-proxy"]' || fail 'unexpected entrypoint'

run() {
  docker run --rm --label "$label" --network none --read-only "$image" "$@"
}

# stdout only: docker prints a platform mismatch warning on stderr for emulated arm64 runs.
out=$(run version) || fail 'version failed'
test "$out" = "$version" || fail "version does not report $version: $out"

# Negative: an unknown flag is rejected with a diagnostic.
if run server --definitely-not-a-flag >"$work/bad-flag.log" 2>&1; then
  fail 'unknown flag was accepted'
fi
grep -q 'unknown flag: --definitely-not-a-flag' "$work/bad-flag.log" ||
  fail "unexpected unknown-flag error: $(cat "$work/bad-flag.log")"

# Negative: a malformed broker mapping is rejected before the proxy listens.
if run server --bootstrap-server-mapping 'not-a-mapping' >"$work/bad-mapping.log" 2>&1; then
  fail 'malformed bootstrap-server-mapping was accepted'
fi
grep -q 'server-mapping must be in form' "$work/bad-mapping.log" ||
  fail "unexpected bad-mapping error: $(cat "$work/bad-mapping.log")"

# The broker sits on a backend network only. Clients sit on a frontend network
# only, so a produce/consume round trip proves the proxy rewrote the broker's
# advertised address: the client cannot resolve the broker name directly.
docker network create --label "$label" --internal "$backend" >/dev/null
docker network create --label "$label" --internal "$frontend" >/dev/null

docker pull --quiet "$kafka" >/dev/null
docker run -d --name "$broker" --label "$label" --network "$backend" --entrypoint sh "$kafka" -c '
  set -e
  config=/opt/kafka/config/server.properties
  kafka-storage.sh format --standalone -t "$(kafka-storage.sh random-uuid | tail -n1)" -c "$config"
  exec kafka-server-start.sh "$config" \
    --override advertised.listeners=PLAINTEXT://'"$broker"':9092,CONTROLLER://localhost:9093
' >/dev/null

i=0
until docker exec "$broker" kafka-broker-api-versions.sh --bootstrap-server "$broker:9092" \
  >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$(docker inspect -f '{{.State.Running}}' "$broker")" = true ] ||
    { dump "$broker"; fail 'broker exited early'; }
  [ "$i" -le 90 ] || { dump "$broker"; fail 'broker did not become ready'; }
  sleep 2
done

start_proxy() {
  name=$1
  network=$2
  shift 2
  docker run -d --name "$name" --label "$label" --network "$network" --read-only "$image" \
    server --dynamic-listeners-disable "$@" >/dev/null
  docker network connect "$frontend" "$name"
}

start_proxy "$proxy" "$backend" \
  --bootstrap-server-mapping "$broker:9092,0.0.0.0:32400,$proxy:32400"

# Every client run is bounded; a timed-out container is removed by the label cleanup.
client() {
  timeout 180 docker run --rm -i --label "$label" --network "$frontend" --entrypoint sh "$kafka" -c "$1"
}

# The proxy needs a few seconds to listen; the client probes through it until the API answers.
i=0
until client "kafka-broker-api-versions.sh --bootstrap-server $proxy:32400" \
  >"$work/api.log" 2>&1; do
  i=$((i + 1))
  [ "$(docker inspect -f '{{.State.Running}}' "$proxy")" = true ] ||
    { dump "$proxy"; fail 'proxy exited early'; }
  [ "$i" -le 30 ] || { cat "$work/api.log" >&2; dump "$proxy"; fail 'proxy did not become ready'; }
  sleep 2
done
grep -q "^$proxy:32400 (id: 1 rack: null" "$work/api.log" ||
  { cat "$work/api.log" >&2; fail 'broker metadata was not rewritten to the proxy address'; }

docker logs "$proxy" 2>&1 | grep -q "Starting kafka-proxy version $version" ||
  { dump "$proxy"; fail 'proxy did not log its version at startup'; }

# The broker name must not resolve from the frontend, or the round trip proves nothing.
if client "kafka-broker-api-versions.sh --bootstrap-server $broker:9092" >/dev/null 2>&1; then
  fail 'client reached the broker directly; the test topology is not isolating the proxy'
fi

topic="verity-smoke-$$"
payload="verity-kafka-proxy-$$-$(date +%s)"
client "kafka-topics.sh --bootstrap-server $proxy:32400 --create --topic $topic \
  --partitions 1 --replication-factor 1" >"$work/topic.log" 2>&1 ||
  { cat "$work/topic.log" >&2; dump "$proxy"; fail 'topic create through the proxy failed'; }
printf '%s\n' "$payload" |
  client "kafka-console-producer.sh --bootstrap-server $proxy:32400 --topic $topic" \
    >"$work/produce.log" 2>&1 ||
  { cat "$work/produce.log" >&2; dump "$proxy"; fail 'produce through the proxy failed'; }
got=$(client "kafka-console-consumer.sh --bootstrap-server $proxy:32400 --topic $topic \
  --from-beginning --max-messages 1 --timeout-ms 30000" 2>"$work/consume.log") ||
  { cat "$work/consume.log" >&2; dump "$proxy"; fail 'consume through the proxy failed'; }
test "$got" = "$payload" || fail "payload mismatch through the proxy: got '$got'"

# The message reached the real broker, not some proxy-local buffer.
got=$(docker exec "$broker" kafka-console-consumer.sh --bootstrap-server "$broker:9092" \
  --topic "$topic" --from-beginning --max-messages 1 --timeout-ms 30000 2>/dev/null) ||
  fail 'consume directly from the broker failed'
test "$got" = "$payload" || fail "payload mismatch on the broker: got '$got'"

# Negative clients use bounded timeouts so failure is reported instead of hanging.
negative_client() {
  client "printf 'request.timeout.ms=5000\ndefault.api.timeout.ms=15000\n' >/tmp/client.properties
    kafka-topics.sh --bootstrap-server $1 --command-config /tmp/client.properties --list"
}

# Negative: a proxy mapped to an absent broker fails the client and logs the dial error.
start_proxy "$absent" "$backend" \
  --bootstrap-server-mapping "no-such-broker-$$:9092,0.0.0.0:32400,$absent:32400"
sleep 3
if negative_client "$absent:32400" >"$work/absent.log" 2>&1; then
  fail 'client succeeded through a proxy whose broker is absent'
fi
# Startup already logs the remote address, so match only the failed dial.
docker logs "$absent" 2>&1 | grep -qF "couldn't connect to no-such-broker-$$:9092" ||
  { dump "$absent"; fail 'proxy did not report the absent broker'; }

# Negative: with dynamic listeners disabled, a broker advertised under an
# address the proxy does not map is refused instead of leaking to the client.
# The bootstrap name is only reachable through the dial mapping, so the proxy
# connects, but the metadata names "$broker:9092", which has no listener.
start_proxy "$unmapped" "$backend" \
  --bootstrap-server-mapping "bootstrap-alias-$$:9092,0.0.0.0:32400,$unmapped:32400" \
  --dial-address-mapping "bootstrap-alias-$$:9092,$broker:9092"
sleep 3
if negative_client "$unmapped:32400" >"$work/unmapped.log" 2>&1; then
  fail 'client succeeded although the broker advertised an unmapped address'
fi
# Startup already logs the dial mapping to "$broker:9092", so match only the refusal.
docker logs "$unmapped" 2>&1 | grep -qF "net address mapping for $broker:9092 was not found" ||
  { dump "$unmapped"; fail 'proxy did not report the unmapped broker address'; }

printf 'SMOKE PASS\n'
