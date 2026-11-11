#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
label=verity.test=cadvisor-$$
container="verity-cadvisor-test-$$"
work=$(mktemp -d)

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -fv >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  docker logs "$container" >&2 2>/dev/null || true
  printf '%s\n' "$1" >&2
  exit 1
}

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'

# Upstream runs cAdvisor as root so the container runtime socket and /var/lib/docker are readable.
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 0 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/cadvisor","-logtostderr"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = / ||
  fail 'unexpected working directory'

docker run --rm --network none --read-only "$image" --version >"$work/version" 2>&1 ||
  fail 'cadvisor --version failed'
grep -F "version v$expected_version " "$work/version" >/dev/null ||
  fail "cadvisor --version does not report v$expected_version"

if docker run --rm --network none --read-only "$image" --definitely-invalid \
  >"$work/invalid" 2>&1; then
  fail 'invalid flag unexpectedly succeeded'
fi
grep -F 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'invalid flag diagnostic is missing'

if docker run --rm --network none --read-only "$image" --port=not-a-port \
  >"$work/badport" 2>&1; then
  fail 'invalid port value unexpectedly succeeded'
fi
grep -F 'invalid value "not-a-port" for flag -port' "$work/badport" >/dev/null ||
  fail 'invalid port diagnostic is missing'

# A known container the daemon must discover with its name label.
target="verity-cadvisor-target-$$"
docker run -d --label "$label" --name "$target" --network none --read-only "$image" >/dev/null

# Host paths are mounted read-only and the container is not privileged.
docker run -d --label "$label" --name "$container" --read-only \
  -v /sys:/sys:ro \
  -v /var/run:/var/run:ro \
  -v /var/lib/docker:/var/lib/docker:ro \
  -v /dev/disk:/dev/disk:ro \
  -p 127.0.0.1::8080 "$image" \
  --housekeeping_interval=1s >/dev/null
port=$(docker port "$container" 8080/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || fail 'cadvisor port was not published'
base="http://127.0.0.1:$port"

attempts=0
until [ "$(curl --silent --max-time 5 "$base/healthz" 2>/dev/null)" = ok ]; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || fail 'cadvisor did not become healthy'
  [ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ] ||
    fail 'cadvisor exited before it became healthy'
  sleep 1
done

attempts=0
until curl --silent --fail --max-time 10 "$base/metrics" >"$work/metrics" 2>/dev/null &&
  grep -E '^container_cpu_usage_seconds_total\{' "$work/metrics" >/dev/null; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || fail 'container_cpu_usage_seconds_total never appeared in /metrics'
  sleep 1
done

attempts=0
until curl --silent --fail --max-time 10 "$base/metrics" >"$work/metrics" 2>/dev/null &&
  grep -E "^container_cpu_usage_seconds_total\\{[^}]*name=\"$target\"" "$work/metrics" >/dev/null; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || fail "no container_cpu_usage_seconds_total series named $target (docker discovery)"
  sleep 1
done
grep -E "^container_cpu_usage_seconds_total\\{[^}]*image=\"[^\"]+\"[^}]*name=\"$target\"" "$work/metrics" >/dev/null ||
  fail 'discovered container series has no image label'
grep -E '^# TYPE container_cpu_usage_seconds_total counter' "$work/metrics" >/dev/null ||
  fail 'container_cpu_usage_seconds_total has the wrong metric type'
grep -E '^machine_cpu_cores\{[^}]*\} [1-9]' "$work/metrics" >/dev/null ||
  fail 'machine_cpu_cores is missing or zero'
grep -E '^machine_memory_bytes\{[^}]*\} [1-9]' "$work/metrics" >/dev/null ||
  fail 'machine_memory_bytes is missing or zero'
grep -F "cadvisorVersion=\"v$expected_version\"" "$work/metrics" >/dev/null ||
  fail "cadvisor_version_info does not report v$expected_version"

curl --silent --fail --max-time 10 "$base/api/v1.3/machine" >"$work/machine.json" ||
  fail 'machine API request failed'
grep -F '"num_cores"' "$work/machine.json" >/dev/null || fail 'machine API has no num_cores'

[ "$(docker inspect --format '{{.HostConfig.Privileged}}' "$container")" = false ] ||
  fail 'test container must not be privileged'

docker stop -t 20 "$container" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ] ||
  fail 'cadvisor did not exit cleanly on SIGTERM'

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$expected_version"
