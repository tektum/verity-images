#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE [FLAVOR]}
flavor=${2:-plain}
recipe="$(dirname "$0")/../melange.yaml"
expected_version=$(sed -n 's/^  version: "\([^"]*\)".*$/\1/p' "$recipe")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
label=verity-kafka-test=$$
volume=verity-kafka-data-$$
broker=verity-kafka-broker-$$
work=$(mktemp -d)

cleanup() {
  docker rm -f "$broker" "$broker-neg" >/dev/null 2>&1 || true
  docker volume rm "$volume" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

broker_fail() {
  docker logs "$broker" >&2 2>&1 || true
  fail "$1"
}

case $flavor in plain) ;; *) fail "unsupported flavor $flavor" ;; esac

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 9092 ] || fail 'unexpected OCI user'

docker run --rm --label "$label" --entrypoint kafka-topics.sh "$image" --version >"$work/version.log" 2>&1 ||
  fail 'kafka-topics.sh --version failed'
grep -q "$expected_version" "$work/version.log" || fail 'unexpected Kafka version'
docker run --rm --label "$label" --entrypoint sh "$image" -c 'ls /opt/kafka/libs | grep -qi zookeeper' &&
  fail 'ZooKeeper jar present'

# Negative case: an unformatted log directory must make the broker exit non-zero with a readable error.
rc=0
timeout 120 docker run --rm --name "$broker-neg" "$image" >"$work/neg.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'broker started without formatted storage'
[ "$rc" -ne 124 ] || fail 'broker hung on unformatted storage instead of exiting'
grep -qiE 'meta.properties|not formatted|kafka-storage|format' "$work/neg.log" ||
  { cat "$work/neg.log" >&2; fail 'unreadable error for unformatted storage'; }

docker volume create --label "$label" "$volume" >/dev/null
cluster_id=$(docker run --rm --label "$label" --entrypoint kafka-storage.sh "$image" random-uuid | tail -n1)
[ -n "$cluster_id" ] || fail 'no cluster id generated'
docker run --rm --label "$label" -v "$volume:/var/lib/kafka" --entrypoint kafka-storage.sh "$image" \
  format --standalone -t "$cluster_id" -c /opt/kafka/config/server.properties >"$work/format.log" 2>&1 ||
  { cat "$work/format.log" >&2; fail 'kafka-storage format failed'; }

start_broker() {
  docker rm -f "$broker" >/dev/null 2>&1 || true
  docker run -d --name "$broker" --label "$label" -v "$volume:/var/lib/kafka" "$image" >/dev/null
  i=0
  until docker exec "$broker" kafka-broker-api-versions.sh --bootstrap-server localhost:9092 >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -le 90 ] || broker_fail 'broker did not become ready'
    [ "$(docker inspect -f '{{.State.Running}}' "$broker")" = true ] || broker_fail 'broker exited early'
    sleep 2
  done
}

start_broker
docker exec "$broker" kafka-topics.sh --bootstrap-server localhost:9092 --create --topic smoke \
  --partitions 1 --replication-factor 1 >/dev/null || broker_fail 'topic create failed'
payload="verity-payload-$$"
printf '%s\n' "$payload" | docker exec -i "$broker" kafka-console-producer.sh \
  --bootstrap-server localhost:9092 --topic smoke >/dev/null 2>&1 || broker_fail 'produce failed'
got=$(docker exec "$broker" kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic smoke \
  --from-beginning --max-messages 1 --timeout-ms 30000 2>/dev/null) || broker_fail 'consume failed'
[ "$got" = "$payload" ] || fail "payload mismatch: $got"

# Persistence: restart on the same volume and read the message again.
docker stop "$broker" >/dev/null
start_broker
got=$(docker exec "$broker" kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic smoke \
  --from-beginning --max-messages 1 --timeout-ms 30000 2>/dev/null) || broker_fail 'consume after restart failed'
[ "$got" = "$payload" ] || fail "data lost across restart: $got"

printf 'SMOKE PASS image=%s\n' "$image"
