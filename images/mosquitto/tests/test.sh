#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-mosquitto-test-$$"
volume="verity-mosquitto-data-$$"
fixture=$(mktemp -d)

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
  rm -rf "$fixture"
}
trap cleanup EXIT INT TERM

wait_ready() {
  i=0
  until docker run --rm --cpus 4 --network "container:$container" \
    --entrypoint /usr/bin/mosquitto_pub "$image" \
    -h 127.0.0.1 -p 1883 -t verity/ready -m ready >/dev/null 2>&1; do
    [ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ] || {
      docker logs "$container" >&2
      fail 'broker exited before becoming ready'
    }
    i=$((i + 1))
    [ "$i" -lt 30 ] || {
      docker logs "$container" >&2
      fail 'broker did not become ready'
    }
    sleep 1
  done
}

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 1883 ] || fail 'image user is not 1883'
[ "$(docker image inspect --format '{{json .Config.Volumes}}' "$image" | grep -Fc '"/mosquitto/data"')" -eq 1 ] || fail 'missing data volume'
[ "$(docker image inspect --format '{{json .Config.Volumes}}' "$image" | grep -Fc '"/mosquitto/log"')" -eq 1 ] || fail 'missing log volume'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/mosquitto"]' ] || fail 'unexpected image entrypoint'
[ "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["-c","/mosquitto/config/mosquitto.conf"]' ] || fail 'unexpected image command'
docker run --rm --cpus 4 "$image" -h 2>&1 | grep -F 'mosquitto version 2.1.2' >/dev/null || fail 'mosquitto version check failed'

docker run --name "$container" --cpus 4 --cap-drop=ALL --read-only -d "$image" >/dev/null
wait_ready

docker run --rm --cpus 4 --network "container:$container" \
  --entrypoint /usr/bin/mosquitto_pub "$image" \
  -h 127.0.0.1 -p 1883 -t verity/smoke -m accepted -r
message=$(docker run --rm --cpus 4 --network "container:$container" \
  --entrypoint /usr/bin/mosquitto_sub "$image" \
  -h 127.0.0.1 -p 1883 -t verity/smoke -C 1 -W 5 -F '%p')
[ "$message" = accepted ] || fail "unexpected MQTT payload: $message"

docker rm -f "$container" >/dev/null
cat > "$fixture/persistent.conf" <<'EOF'
listener 1883
allow_anonymous true
persistence true
persistence_location /mosquitto/data/
autosave_interval 1
log_dest stdout
EOF
chmod 644 "$fixture/persistent.conf"
docker volume create "$volume" >/dev/null
docker run --name "$container" --cpus 4 --cap-drop=ALL --read-only -d \
  -v "$fixture/persistent.conf:/mosquitto/config/mosquitto.conf:ro" \
  -v "$volume:/mosquitto/data" "$image" >/dev/null
wait_ready
docker run --rm --cpus 4 --network "container:$container" \
  --entrypoint /usr/bin/mosquitto_pub "$image" \
  -h 127.0.0.1 -p 1883 -t verity/persist -m persisted -r
docker stop "$container" >/dev/null
docker rm "$container" >/dev/null
docker run --name "$container" --cpus 4 --cap-drop=ALL --read-only -d \
  -v "$fixture/persistent.conf:/mosquitto/config/mosquitto.conf:ro" \
  -v "$volume:/mosquitto/data" "$image" >/dev/null
wait_ready
message=$(docker run --rm --cpus 4 --network "container:$container" \
  --entrypoint /usr/bin/mosquitto_sub "$image" \
  -h 127.0.0.1 -p 1883 -t verity/persist -C 1 -W 5 -F '%p')
[ "$message" = persisted ] || fail "retained MQTT payload did not survive restart: $message"

if docker run --rm --cpus 4 "$image" -c /mosquitto/config/missing.conf > "$fixture/missing.log" 2>&1; then
  fail 'missing config unexpectedly succeeded'
fi
grep -F 'Unable to open config file' "$fixture/missing.log" >/dev/null || fail 'missing config diagnostic not found'

cat > "$fixture/invalid.conf" <<'EOF'
listener invalid
allow_anonymous true
EOF
chmod 644 "$fixture/invalid.conf"
if docker run --rm --cpus 4 \
  -v "$fixture/invalid.conf:/mosquitto/config/mosquitto.conf:ro" \
  "$image" > "$fixture/invalid.log" 2>&1; then
  fail 'invalid listener config unexpectedly succeeded'
fi
grep -F "Error: 'listener port' value not a number" "$fixture/invalid.log" >/dev/null || fail 'invalid listener diagnostic not found'

printf 'SMOKE PASS image=%s\n' "$image"
