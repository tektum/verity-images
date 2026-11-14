#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
recipe_value() {
  awk -v key="$1" '$1 == key { gsub(/"/, "", $2); print $2; exit }' "$here/../melange.yaml"
}
version=$(recipe_value version:)
commit=$(recipe_value source-commit:)
# Catalog Kafka 4.4 (KRaft), pinned by index digest, provides the broker.
kafka_index=ghcr.io/tektum/kafka@sha256:410f7cb53ae8d7ef900635efd21918d033f1ba50a9d5fb1549725d8b0df29c98
label="verity-test=kaf-$$"
network="verity-kaf-$$"
broker="verity-kaf-broker-$$"
consumer="verity-kaf-consumer-$$"
topic=verity-orders
work=$(mktemp -d)

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  for name in "$consumer" "$broker"; do
    docker logs "$name" >/dev/null 2>&1 || continue
    printf -- '--- logs: %s\n' "$name" >&2
    docker logs "$name" 2>&1 | tail -n 30 >&2 || true
  done
  exit 1
}

[ -n "$version" ] || fail 'could not read the recipe version'
[ -n "$commit" ] || fail 'could not read the recipe source commit'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/kaf"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'

offline() {
  docker run --rm --label "$label" --network none --read-only --cap-drop=ALL "$image" "$@"
}

# stdout only: docker prints a platform mismatch warning on stderr for emulated arm64 runs.
out=$(offline --version) || fail 'version failed'
test "$out" = "kaf version $version ($commit)" || fail "unexpected version: $out"

status=0
offline --definitely-invalid >"$work/invalid" 2>&1 || status=$?
test "$status" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"

# Negative: an unreachable broker is an error, not an empty listing.
status=0
offline -b 127.0.0.1:9 topics >"$work/nobroker" 2>&1 || status=$?
test "$status" -ne 0 || fail 'topics without a broker unexpectedly succeeded'
grep -F 'run out of available brokers' "$work/nobroker" >/dev/null ||
  fail "unreachable broker diagnostic is missing: $(cat "$work/nobroker")"

# pull_child INDEX: pull the pinned index by its per-platform child digest,
# verifying the index bytes against the pin first so the pin stays authoritative.
# Pulling the index itself for a second platform fails with "cannot overwrite digest".
image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
pull_child() {
  raw=$(docker buildx imagetools inspect --raw "$1") || fail "cannot inspect $1"
  [ "sha256:$(printf '%s' "$raw" | sha256sum | cut -d' ' -f1)" = "${1#*@}" ] ||
    fail "index digest mismatch for $1"
  child=$(printf '%s' "$raw" | jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') || fail "cannot resolve a child of $1"
  case $child in
    sha256:*) ;;
    *) fail "no unique linux/$image_arch child in $1" ;;
  esac
  docker pull --quiet --platform "linux/$image_arch" "${1%%@*}@$child" >/dev/null ||
    fail "cannot pull ${1%%@*}@$child"
  printf '%s' "${1%%@*}@$child"
}
kafka=$(pull_child "$kafka_index")

# The broker and every kaf run share an internal network with no outside route.
docker network create --label "$label" --internal "$network" >/dev/null
docker run -d --name "$broker" --label "$label" --network "$network" --entrypoint sh "$kafka" -c '
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
  [ "$(docker inspect -f '{{.State.Running}}' "$broker")" = true ] || fail 'broker exited early'
  [ "$i" -le 90 ] || fail 'broker did not become ready'
  sleep 2
done

# Every client run is bounded; a timed-out container is removed by the label cleanup.
kaf() {
  timeout 120 docker run --rm -i --label "$label" --network "$network" --read-only --cap-drop=ALL \
    "$image" -b "$broker:9092" "$@"
}

kaf node ls >"$work/nodes" 2>&1 || fail "node ls failed: $(cat "$work/nodes")"
grep -E "^1 +$broker:9092 +true *\$" "$work/nodes" >/dev/null ||
  fail "node ls does not show the controller broker: $(cat "$work/nodes")"

kaf topic create "$topic" -p 3 -r 1 >"$work/create" 2>&1 || fail "topic create failed: $(cat "$work/create")"
grep -E '^ +Partitions: +3$' "$work/create" >/dev/null || fail "unexpected create output: $(cat "$work/create")"

# Negative: creating the same topic again is rejected by the broker.
status=0
kaf topic create "$topic" -p 3 -r 1 >"$work/dup" 2>&1 || status=$?
test "$status" -ne 0 || fail 'duplicate topic create unexpectedly succeeded'
grep -F "Topic '$topic' already exists" "$work/dup" >/dev/null ||
  fail "duplicate topic diagnostic is missing: $(cat "$work/dup")"

kaf topics >"$work/topics" 2>&1 || fail "topics failed: $(cat "$work/topics")"
grep -E "^$topic +3 +1 *\$" "$work/topics" >/dev/null || fail "topic is not listed: $(cat "$work/topics")"

# Three keyed records with a header land on one partition, in order.
printf 'alpha\nbeta\ngamma\n' |
  kaf produce "$topic" -k order-1 -H source:verity --input-mode line >"$work/produce" 2>&1 ||
  fail "produce failed: $(cat "$work/produce")"
test "$(grep -c '^Sent record to partition ' "$work/produce")" = 3 ||
  fail "unexpected produce output: $(cat "$work/produce")"
partition=$(sed -n 's/^Sent record to partition \([0-9]*\) at offset 0\.$/\1/p' "$work/produce")
[ -n "$partition" ] || fail "first record was not written at offset 0: $(cat "$work/produce")"
grep -Fx "Sent record to partition $partition at offset 2." "$work/produce" >/dev/null ||
  fail "records did not share one partition: $(cat "$work/produce")"

kaf consume "$topic" --offset oldest --output json >"$work/json" 2>&1 ||
  fail "consume failed: $(cat "$work/json")"
jq -r '.payload' "$work/json" >"$work/payloads" 2>/dev/null || fail "consume output is not JSON: $(cat "$work/json")"
printf 'alpha\nbeta\ngamma\n' | cmp -s - "$work/payloads" || fail "unexpected payloads: $(cat "$work/payloads")"
test "$(jq -r 'select(.offset == 1) | "\(.key) \(.partition) \(.headers[0].Key | @base64d)=\(.headers[0].Value | @base64d)"' \
  "$work/json")" = "order-1 $partition source=verity" || fail "key, partition or header lost: $(cat "$work/json")"

# A single partition and offset, limited to one record.
out=$(kaf consume "$topic" -p "$partition" --offset 1 -l 1 --output raw) || fail 'offset consume failed'
test "$out" = beta || fail "offset 1 is not beta: $out"

# A consumer group member commits what it consumed; then it is stopped and
# the group's committed offsets and lag are read back.
docker run -d --name "$consumer" --label "$label" --network "$network" --read-only --cap-drop=ALL \
  "$image" -b "$broker:9092" consume "$topic" -g verity-group --commit --offset oldest --output raw >/dev/null
i=0
until kaf group describe verity-group 2>/dev/null | grep -Eq '^ +Total +3 +0 *$'; do
  i=$((i + 1))
  [ "$(docker inspect -f '{{.State.Running}}' "$consumer")" = true ] || fail 'group consumer exited early'
  [ "$i" -le 60 ] || fail "group did not commit offset 3: $(kaf group describe verity-group 2>&1)"
  sleep 2
done
test "$(docker logs "$consumer" 2>/dev/null)" = "$(printf 'alpha\nbeta\ngamma')" ||
  fail "group consumer did not receive the records: $(docker logs "$consumer" 2>&1)"
docker rm -f "$consumer" >/dev/null

printf 'delta\n' | kaf produce "$topic" -k order-1 --input-mode line >/dev/null 2>&1 || fail 'second produce failed'
kaf group describe verity-group >"$work/group" 2>&1 || fail "group describe failed: $(cat "$work/group")"
grep -E "^ +$partition +3 +4 +1 *\$" "$work/group" >/dev/null ||
  fail "group does not report offset 3, high watermark 4, lag 1: $(cat "$work/group")"
kaf groups >"$work/groups" 2>&1 || fail "groups failed: $(cat "$work/groups")"
grep -E '^verity-group +' "$work/groups" >/dev/null || fail "group is not listed: $(cat "$work/groups")"

# A named cluster in the config file replaces -b. Only the config directory is writable.
mkdir -p "$work/kafcfg"
chmod 777 "$work/kafcfg"
kafcfg() {
  timeout 120 docker run --rm --label "$label" --network "$network" --read-only --cap-drop=ALL \
    -v "$work/kafcfg:/home/nonroot/.kaf" "$image" "$@"
}
kafcfg config add-cluster local -b "$broker:9092" >"$work/add" 2>&1 || fail "add-cluster failed: $(cat "$work/add")"
kafcfg config use-cluster local >"$work/use" 2>&1 || fail "use-cluster failed: $(cat "$work/use")"
grep -Fx "  - $broker:9092" "$work/kafcfg/config" >/dev/null || fail "config file lacks the broker: $(cat "$work/kafcfg/config")"
grep -Fx 'current-cluster: local' "$work/kafcfg/config" >/dev/null || fail 'config file has no current cluster'
kafcfg topics >"$work/cfgtopics" 2>&1 || fail "topics from config failed: $(cat "$work/cfgtopics")"
grep -E "^$topic +3 +1 *\$" "$work/cfgtopics" >/dev/null || fail "config cluster does not list the topic: $(cat "$work/cfgtopics")"
kafcfg config get-clusters >"$work/clusters" 2>&1 || fail "get-clusters failed: $(cat "$work/clusters")"
grep -Fx local "$work/clusters" >/dev/null || fail "get-clusters does not list local: $(cat "$work/clusters")"
# Negative: an unknown cluster is reported (upstream exits 0) and the current one is kept.
kafcfg config use-cluster missing >"$work/missing" 2>&1 || true
grep -Fx 'Cluster with name missing not found' "$work/missing" >/dev/null ||
  fail "unknown cluster diagnostic is missing: $(cat "$work/missing")"
grep -Fx 'current-cluster: local' "$work/kafcfg/config" >/dev/null ||
  fail "an unknown cluster replaced the current one: $(cat "$work/kafcfg/config")"

echo 'SMOKE PASS'
