#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
config="$(dirname "$0")/../apko.yaml"
version=$(sed -n 's/^    - dkron=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
container="verity-dkron-test-$$"
node="verity-smoke-$$"
work=$(mktemp -d)
marker="verity-dkron-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail 'could not read the pinned dkron version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/local/bin/dkron"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = \
  '["agent","--server","--bootstrap-expect=1"]' || fail 'unexpected command'

docker run --rm --network none "$image" version >"$work/version" 2>&1 ||
  fail 'version failed'
grep -Fx "Version: $version" "$work/version" >/dev/null ||
  fail "version does not report $version: $(cat "$work/version")"

test "$(docker run --rm --network none --entrypoint /usr/bin/id "$image" -u)" = 65532 ||
  fail 'container does not run as uid 65532'

rc=0
docker run --rm --network none "$image" agent --definitely-invalid >"$work/flag" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'unknown flag: --definitely-invalid' "$work/flag" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/flag")"

# Single-node server with the default command shape, as the non-root user.
docker run -d --name "$container" -p 127.0.0.1::8080 "$image" \
  agent --server --bootstrap-expect=1 --node-name "$node" --log-level debug >/dev/null
port=$(docker port "$container" 8080/tcp | awk -F: 'NR == 1 { print $NF }')
[ -n "$port" ] || fail 'http port is not published'
api="http://127.0.0.1:$port"

i=0
until leader=$(curl --fail --silent --connect-timeout 1 --max-time 5 "$api/v1/leader") &&
  printf '%s' "$leader" | grep -F "\"Name\":\"$node\"" >/dev/null; do
  i=$((i + 1))
  if [ "$i" -ge 60 ]; then
    docker logs "$container" >&2 || true
    fail 'server did not elect itself leader'
  fi
  sleep 1
done

# Every bundled executor and processor plugin must be discovered and started.
for plugin in executor-gcppubsub executor-grpc executor-kafka executor-nats \
  executor-rabbitmq processor-files processor-fluent processor-log processor-syslog; do
  docker logs "$container" 2>&1 |
    grep -F "msg=\"plugin started\"" | grep -F "path=/usr/bin/dkron-$plugin " >/dev/null ||
    fail "plugin dkron-$plugin was not started"
done

post_job() {
  curl --silent --show-error --max-time 10 -o "$work/body" -w '%{http_code}' \
    -H 'Content-Type: application/json' -d "$1" "$api/v1/jobs"
}

code=$(post_job "{
  \"name\": \"verity-smoke\",
  \"schedule\": \"@every 2s\",
  \"executor\": \"shell\",
  \"executor_config\": {\"command\": \"echo $marker\"}
}") || fail 'create job request failed'
test "$code" = 201 || fail "create job returned $code: $(cat "$work/body")"

# shell: true runs through /bin/sh, which upstream jobs commonly rely on.
code=$(post_job "{
  \"name\": \"verity-shell\",
  \"schedule\": \"@every 1h\",
  \"executor\": \"shell\",
  \"executor_config\": {\"shell\": \"true\", \"command\": \"printf '%s-%s\\\\n' $marker piped | tr '[:lower:]' '[:upper:]'\"}
}") || fail 'create shell job request failed'
test "$code" = 201 || fail "create shell job returned $code: $(cat "$work/body")"
code=$(curl --silent --show-error --max-time 10 -o "$work/body" -w '%{http_code}' \
  -X POST "$api/v1/jobs/verity-shell/run") || fail 'run shell job request failed'
test "$code" = 200 || fail "run shell job returned $code: $(cat "$work/body")"

wait_execution() {
  i=0
  until curl --fail --silent --max-time 5 "$api/v1/jobs/$1/executions" >"$work/executions" &&
    python3 - "$work/executions" "$2" <<'EOF'
import json, sys
executions = json.load(open(sys.argv[1]))
sys.exit(0 if any(e.get("success") is True and sys.argv[2] in e.get("output", "")
                  for e in executions or []) else 1)
EOF
  do
    i=$((i + 1))
    if [ "$i" -ge 60 ]; then
      cat "$work/executions" >&2 || true
      docker logs "$container" >&2 || true
      fail "job $1 has no successful execution with output $2"
    fi
    sleep 1
  done
}

wait_execution verity-smoke "$marker"
upper=$(printf '%s-piped' "$marker" | tr '[:lower:]' '[:upper:]')
wait_execution verity-shell "$upper"

# Invalid schedules are rejected and not stored.
code=$(post_job '{
  "name": "verity-invalid",
  "schedule": "definitely not a schedule",
  "executor": "shell",
  "executor_config": {"command": "echo never"}
}') || fail 'invalid job request failed'
case "$code" in
  4??) ;;
  *) fail "invalid schedule returned $code: $(cat "$work/body")" ;;
esac
grep -F "can't parse job schedule" "$work/body" >/dev/null ||
  fail "invalid schedule diagnostic is missing: $(cat "$work/body")"
code=$(curl --silent --max-time 5 -o /dev/null -w '%{http_code}' "$api/v1/jobs/verity-invalid") || true
test "$code" = 404 || fail "invalid job was stored (status $code)"

# Raft state lives in the writable default data dir.
docker exec "$container" test -d /dkron.data/raft ||
  fail 'raft state was not written to /dkron.data'

printf 'dkron %s smoke test passed\n' "$version"
