#!/bin/sh
# Offline smoke test: no AWS credentials are passed and every container runs
# with --network none. It proves config translation and validation, then an
# agent started by start-amazon-cloudwatch-agent serving StatsD on UDP 8125
# until a clean SIGTERM shutdown.
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
label=verity.test=amazon-cloudwatch-agent-$$
container="verity-amazon-cloudwatch-agent-test-$$"
agent_dir=/opt/aws/amazon-cloudwatch-agent
work=$(mktemp -d)

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -fv >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  docker logs "$container" >&2 2>/dev/null || true
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

expect() {
  grep -F -- "$2" "$1" >/dev/null || {
    cat "$1" >&2
    fail "$(basename "$1") lacks: $2"
  }
}

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'

# OCI contract of public.ecr.aws/cloudwatch-agent/cloudwatch-agent.
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 0 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  "[\"$agent_dir/bin/start-amazon-cloudwatch-agent\"]" || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = / ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" \
  >"$work/env"
grep -Fx 'RUN_IN_CONTAINER=True' "$work/env" >/dev/null || fail 'RUN_IN_CONTAINER=True is not set'
if grep -E '^AWS_' "$work/env" >/dev/null; then
  fail 'the image bakes in AWS environment'
fi

# Upstream layout under /opt/aws/amazon-cloudwatch-agent.
docker create --label "$label" --name "$container-layout" "$image" >/dev/null
docker export "$container-layout" | tar -tvf - >"$work/layout"
docker rm "$container-layout" >/dev/null
for path in bin/amazon-cloudwatch-agent bin/config-translator bin/config-downloader \
  bin/start-amazon-cloudwatch-agent; do
  grep -E "^-rwxr-xr-x .* ${agent_dir#/}/$path\$" "$work/layout" >/dev/null ||
    fail "missing executable $agent_dir/$path"
done
for path in bin/CWAGENT_VERSION etc/common-config.toml doc/amazon-cloudwatch-agent-schema.json \
  LICENSE NOTICE THIRD-PARTY-LICENSES RELEASE_NOTES; do
  grep -E "^-rw-r--r-- .* ${agent_dir#/}/$path\$" "$work/layout" >/dev/null ||
    fail "missing file $agent_dir/$path"
done
for path in etc/amazon-cloudwatch-agent.d var logs; do
  grep -E "^d.* ${agent_dir#/}/$path/?\$" "$work/layout" >/dev/null ||
    fail "missing directory $agent_dir/$path"
done
grep -E '^drwxrwxrwt .* tmp/?$' "$work/layout" >/dev/null || fail '/tmp is not 1777'

# The agent reads its version from bin/CWAGENT_VERSION beside the executable.
docker run --rm --network none --entrypoint "$agent_dir/bin/amazon-cloudwatch-agent" \
  "$image" -version >"$work/version" 2>&1 || fail 'amazon-cloudwatch-agent -version failed'
expect "$work/version" "CWAgent/$expected_version (go"
printf 'version: %s\n' "$(cat "$work/version")"

# (1a) A valid JSON config is validated and translated to TOML and YAML.
mkdir "$work/translate"
chmod 0777 "$work/translate"
cat >"$work/translate/valid.json" <<'JSON'
{
  "agent": {"region": "us-west-2", "metrics_collection_interval": 10},
  "metrics": {
    "namespace": "VeritySmoke",
    "metrics_collected": {
      "statsd": {
        "service_address": ":8125",
        "metrics_collection_interval": 10,
        "metrics_aggregation_interval": 60
      }
    }
  }
}
JSON
docker run --rm --network none -v "$work/translate:/work" \
  --entrypoint "$agent_dir/bin/config-translator" "$image" \
  -input /work/valid.json -output /work/valid.toml -mode onPrem -os linux \
  >"$work/translate.log" 2>&1 || {
  cat "$work/translate.log" >&2
  fail 'config-translator rejected a valid config'
}
expect "$work/translate.log" 'I! Valid Json input schema.'
expect "$work/translate.log" 'Configuration validation first phase succeeded'
toml="$work/translate/valid.toml"
yaml="$work/translate/amazon-cloudwatch-agent.yaml"
[ -s "$toml" ] || fail 'config-translator wrote no TOML'
[ -s "$yaml" ] || fail 'config-translator wrote no YAML'
expect "$toml" '[[inputs.statsd]]'
expect "$toml" 'service_address = ":8125"'
expect "$toml" '"aws:AggregationInterval" = "60s"'
expect "$toml" '[[outputs.cloudwatch]]'
expect "$yaml" 'namespace: VeritySmoke'
expect "$yaml" 'region: us-west-2'
expect "$yaml" 'mode: onPrem'
expect "$yaml" 'telegraf_statsd:'
expect "$yaml" '- telegraf_statsd'
printf 'translate: %s\n' "$(grep -F 'service_address' "$toml" | tr -s ' ')"

# (1b) An invalid config is rejected with schema errors and produces no output.
cat >"$work/translate/invalid.json" <<'JSON'
{
  "agent": {"region": "us-west-2"},
  "metrics": {"metrics_collected": {"statsd": {"service_address": 8125}}}
}
JSON
if docker run --rm --network none -v "$work/translate:/work" \
  --entrypoint "$agent_dir/bin/config-translator" "$image" \
  -input /work/invalid.json -output /work/invalid.toml -mode onPrem -os linux \
  >"$work/invalid.log" 2>&1; then
  cat "$work/invalid.log" >&2
  fail 'config-translator accepted an invalid config'
fi
expect "$work/invalid.log" 'E! Invalid Json input schema.'
expect "$work/invalid.log" \
  'Under path : /metrics/metrics_collected/statsd/service_address | Error : Invalid type. Expected: string, given: integer'
expect "$work/invalid.log" 'E! configuration validation first phase failed.'
[ ! -e "$work/translate/invalid.toml" ] || fail 'an invalid config produced TOML'
printf 'invalid: %s\n' "$(grep -F 'Under path' "$work/invalid.log")"

# (2) start-amazon-cloudwatch-agent translates /etc/cwagentconfig, execs the
# agent as PID 1, and serves StatsD with no network and no credentials.
mkdir "$work/cwagentconfig"
cp "$work/translate/valid.json" "$work/cwagentconfig/config.json"
chmod 0755 "$work/cwagentconfig"
chmod 0644 "$work/cwagentconfig/config.json"
docker run -d --label "$label" --name "$container" --network none \
  -v "$work/cwagentconfig:/etc/cwagentconfig:ro" "$image" >/dev/null

# Mode auto probes IMDS, ECS, Azure, and GCP before falling back to on-prem.
ready=
i=0
while [ "$i" -lt 180 ]; do
  [ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ] ||
    fail 'the agent exited during startup'
  if docker logs "$container" 2>&1 | grep -F 'Statsd listener listening on:' >/dev/null; then
    ready=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ -n "$ready" ] || fail 'the agent did not report a StatsD listener'
docker logs "$container" >"$work/start.log" 2>&1
expect "$work/start.log" 'I! Detected the instance is OnPremise'
expect "$work/start.log" "I! Config has been translated into TOML $agent_dir/etc/amazon-cloudwatch-agent.toml"
expect "$work/start.log" 'service_address = ":8125"'
expect "$work/start.log" "I! Starting AmazonCloudWatchAgent CWAgent/$expected_version (go"
expect "$work/start.log" 'I! Started the statsd service on :8125'
expect "$work/start.log" 'Everything is ready. Begin running and processing data.'

# The exec chain leaves the agent as PID 1 with the translated config.
pid=$(docker inspect --format '{{.State.Pid}}' "$container")
tr '\0' ' ' <"/proc/$pid/cmdline" >"$work/cmdline"
expect "$work/cmdline" "$agent_dir/bin/amazon-cloudwatch-agent -config $agent_dir/etc/amazon-cloudwatch-agent.toml"
# UDP 8125 is 1FBD in the container network namespace's socket table.
cat "/proc/$pid/net/udp" "/proc/$pid/net/udp6" >"$work/udp"
awk '{ split($2, a, ":"); if (a[2] == "1FBD") found = 1 } END { exit !found }' "$work/udp" ||
  fail 'nothing listens on UDP 8125'
printf 'ready: %s\n' "$(grep -F 'Statsd listener listening on:' "$work/start.log")"

sleep 5
[ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ] ||
  fail 'the agent did not stay up'

docker kill --signal TERM "$container" >/dev/null
status=$(timeout 60 docker wait "$container") || fail 'the agent did not stop after SIGTERM'
[ "$status" = 0 ] || fail "the agent exited $status after SIGTERM"
docker logs "$container" >"$work/stop.log" 2>&1
expect "$work/stop.log" '"msg":"Shutdown complete."'
printf 'sigterm: exit=%s\n' "$status"

printf 'SMOKE PASS image=%s\n' "$image"
