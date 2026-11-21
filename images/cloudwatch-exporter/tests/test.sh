#!/bin/sh
# Offline smoke test. Every exporter container runs with --network none and no
# AWS credentials, so it cannot reach AWS: its network namespace holds only the
# loopback interface. HTTP probes run from a pinned curl fixture that joins that
# namespace and gains no other route. The SDK endpoint also points at a closed
# loopback port, and the instance metadata client is disabled.
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
fixture_index='docker.io/curlimages/curl:8.14.1@sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b'
label=verity.test=cloudwatch-exporter-$$
container="verity-cloudwatch-exporter-test-$$"
work=$(mktemp -d)

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -fv >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  docker logs "$container" 2>&1 | tail -n 40 >&2 || true
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' "$here/../melange.yaml" | head -n 1)
[ -n "$expected_version" ] || fail 'could not read the recipe version'

# A classic Docker image store cannot bind the index digest to a second
# platform's image, so pull the fixture by its own per-platform child digest
# after verifying the index bytes against the pinned digest.
image_arch=$(docker image inspect --format '{{.Architecture}}' "$image")
fixture_raw=$(docker buildx imagetools inspect --raw "$fixture_index") ||
  fail 'cannot inspect fixture image index'
[ "sha256:$(printf '%s' "$fixture_raw" | sha256sum | cut -d' ' -f1)" = "${fixture_index#*@}" ] ||
  fail 'fixture image index digest mismatch'
fixture_digest=$(printf '%s' "$fixture_raw" |
  jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') ||
  fail 'cannot resolve fixture image digest'
case $fixture_digest in
  sha256:*) ;;
  *) fail "no unique linux/$image_arch fixture image in $fixture_index" ;;
esac
fixture=docker.io/curlimages/curl@$fixture_digest
docker pull --quiet --platform "linux/$image_arch" "$fixture" >/dev/null ||
  fail 'cannot pull fixture image'

# Run curl inside the exporter's network namespace.
probe() {
  docker run --rm --label "$label" --network "container:$container" \
    --entrypoint curl "$fixture" --silent --show-error --max-time 30 "$@"
}

# OCI contract of prom/cloudwatch-exporter.
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65534 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["java","-jar","/cloudwatch_exporter.jar","9106"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["/config/config.yml"]' ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = / ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" >"$work/env"
if grep -E '^AWS_' "$work/env" >/dev/null; then
  fail 'the image bakes in AWS environment'
fi

# Like upstream, /config exists but the image ships no configuration, so the
# default command fails with a readable error.
docker run --rm --label "$label" --network none --entrypoint ls "$image" -A /config >"$work/config-listing" ||
  fail '/config is missing'
[ ! -s "$work/config-listing" ] || fail "image ships configuration: $(cat "$work/config-listing")"
if docker run --rm --label "$label" --network none "$image" >"$work/no-config.log" 2>&1; then
  fail 'exporter started without a configuration file'
fi
grep -F '/config/config.yml' "$work/no-config.log" >/dev/null ||
  { cat "$work/no-config.log" >&2; fail 'missing configuration error does not name /config/config.yml'; }

mkdir -p "$work/config"
chmod 755 "$work" "$work/config"

write_config() {
  cat >"$work/config/$1"
  chmod 644 "$work/config/$1"
}

write_config config.yml <<'EOF'
region: us-east-1
metrics:
  - aws_namespace: AWS/ELB
    aws_metric_name: RequestCount
    aws_dimensions: [AvailabilityZone, LoadBalancerName]
    aws_statistics: [Sum]
EOF

# Invalid configurations are rejected at startup.
write_config no-metrics.yml <<'EOF'
region: us-east-1
EOF
write_config no-metric-name.yml <<'EOF'
region: us-east-1
metrics:
  - aws_namespace: AWS/ELB
EOF
for config in no-metrics.yml no-metric-name.yml; do
  if docker run --rm --label "$label" --network none -v "$work/config:/config:ro" \
    "$image" "/config/$config" >"$work/invalid.log" 2>&1; then
    fail "invalid configuration $config was accepted"
  fi
  grep -E 'IllegalArgumentException: Must provide (metrics|aws_namespace and aws_metric_name)' \
    "$work/invalid.log" >/dev/null ||
    { cat "$work/invalid.log" >&2; fail "invalid configuration $config produced no readable error"; }
done

# Start with the default command: port 9106 and /config/config.yml.
docker run -d --label "$label" --name "$container" --network none \
  -e AWS_ENDPOINT_URL=http://127.0.0.1:9 -e AWS_EC2_METADATA_DISABLED=true \
  -v "$work/config:/config:ro" "$image" >/dev/null

test "$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$container")" = none ||
  fail 'exporter is not isolated with --network none'

i=0
until [ "$(probe http://127.0.0.1:9106/-/healthy 2>/dev/null)" = ok ]; do
  [ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ] ||
    fail 'exporter exited during startup'
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'exporter did not report healthy on /-/healthy'
  sleep 1
done
[ "$(probe http://127.0.0.1:9106/-/ready)" = ok ] || fail '/-/ready did not report ok'

# The namespace the exporter runs in has loopback only and no routes.
probe --version >/dev/null || fail 'fixture cannot run in the exporter namespace'
docker run --rm --label "$label" --network "container:$container" --entrypoint cat "$fixture" \
  /proc/net/dev >"$work/netdev"
interfaces=$(awk -F: 'NR > 2 { gsub(/ /, "", $1); print $1 }' "$work/netdev" | sort | tr '\n' ' ')
[ "$interfaces" = 'lo ' ] || fail "exporter namespace has interfaces other than lo: $interfaces"
docker run --rm --label "$label" --network "container:$container" --entrypoint cat "$fixture" \
  /proc/net/route >"$work/route"
[ "$(awk 'NR > 1' "$work/route" | wc -l)" -eq 0 ] || fail 'exporter namespace has an IPv4 route'
# An off-host connection (TEST-NET-1, never routed) fails at once.
if probe --connect-timeout 5 --output /dev/null http://192.0.2.1/ 2>/dev/null; then
  fail 'exporter namespace reached an off-host address'
fi

# Scrapes fail without credentials or network; the error is reported as a
# metric and the exporter keeps serving.
for attempt in 1 2; do
  probe --fail http://127.0.0.1:9106/metrics >"$work/metrics" || fail "scrape $attempt failed"
  grep -Ex 'cloudwatch_exporter_scrape_error 1(\.0)?' "$work/metrics" >/dev/null ||
    { cat "$work/metrics" >&2; fail "scrape $attempt did not report cloudwatch_exporter_scrape_error 1"; }
done
grep -E "^cloudwatch_exporter_build_info\{build_version=\"$expected_version\",release_date=\"[0-9]{4}-[0-9]{2}-[0-9]{2}\",?\} 1(\.0)?\$" \
  "$work/metrics" >/dev/null ||
  { grep -F build_info "$work/metrics" >&2; fail "build info does not report version $expected_version"; }
grep -E '^cloudwatch_exporter_scrape_duration_seconds ' "$work/metrics" >/dev/null ||
  fail 'scrape duration metric missing'
grep -E '^jvm_info\{.*version="25\.' "$work/metrics" >/dev/null ||
  fail 'JVM metrics do not report Java 25'
docker logs "$container" >"$work/run.log" 2>&1
grep -F 'CloudWatch scrape failed' "$work/run.log" >/dev/null || fail 'scrape failure was not logged'
grep -F 'Unable to load credentials' "$work/run.log" >/dev/null ||
  fail 'scrape did not fail on missing credentials'
[ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ] ||
  fail 'exporter exited after a failed scrape'

# /-/reload accepts POST only, applies a valid file, and keeps serving the
# previous configuration when the new file is invalid.
code=$(probe --output /dev/null --write-out '%{http_code}' http://127.0.0.1:9106/-/reload)
[ "$code" = 405 ] || fail "GET /-/reload returned $code, expected 405"
code=$(probe --request TRACE --output /dev/null --write-out '%{http_code}' http://127.0.0.1:9106/metrics)
[ "$code" = 405 ] || fail "TRACE returned $code, expected 405"

write_config config.yml <<'EOF'
region: eu-west-1
period_seconds: 300
metrics:
  - aws_namespace: AWS/EC2
    aws_metric_name: CPUUtilization
    aws_dimensions: [InstanceId]
    aws_statistics: [Average]
EOF
[ "$(probe --fail --request POST http://127.0.0.1:9106/-/reload)" = OK ] ||
  fail 'POST /-/reload did not apply a valid configuration'

write_config config.yml <<'EOF'
region: eu-west-1
EOF
code=$(probe --output /dev/null --write-out '%{http_code}' --request POST http://127.0.0.1:9106/-/reload)
[ "$code" = 500 ] || fail "reload of an invalid configuration returned $code, expected 500"
[ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ] ||
  fail 'exporter exited after an invalid reload'
probe --fail http://127.0.0.1:9106/metrics >"$work/metrics" || fail 'scrape after invalid reload failed'
grep -E '^cloudwatch_exporter_scrape_error ' "$work/metrics" >/dev/null ||
  fail 'exporter stopped reporting scrape errors after an invalid reload'

# SIGHUP reloads the file too: an invalid file is logged as a failed reload and
# the exporter stays up, then a valid file reloads without a new failure.
log_count() {
  docker logs "$container" 2>&1 | grep -c -F "$1" || true
}

wait_for_log_count() {
  i=0
  until [ "$(log_count "$1")" -gt "$2" ]; do
    i=$((i + 1))
    [ "$i" -lt 20 ] || fail "SIGHUP did not log: $1"
    sleep 1
  done
}

failures=$(log_count 'Configuration reload failed')
docker kill --signal HUP "$container" >/dev/null
wait_for_log_count 'Configuration reload failed' "$failures"
[ "$(probe http://127.0.0.1:9106/-/healthy)" = ok ] || fail 'exporter unhealthy after an invalid SIGHUP reload'

write_config config.yml <<'EOF'
region: us-east-1
metrics:
  - aws_namespace: AWS/ELB
    aws_metric_name: RequestCount
    aws_dimensions: [AvailabilityZone, LoadBalancerName]
    aws_statistics: [Sum]
EOF
failures=$(log_count 'Configuration reload failed')
reloads=$(log_count 'Reloading configuration')
docker kill --signal HUP "$container" >/dev/null
wait_for_log_count 'Reloading configuration' "$reloads"
sleep 1
[ "$(log_count 'Configuration reload failed')" -eq "$failures" ] || fail 'SIGHUP reload of a valid file failed'
[ "$(probe http://127.0.0.1:9106/-/healthy)" = ok ] || fail 'exporter unhealthy after SIGHUP reload'

# SIGTERM stops the exporter (exit 0, or 143 when the JVM exits on the signal).
docker stop --time 30 "$container" >/dev/null
exit_code=$(docker inspect --format '{{.State.ExitCode}}' "$container")
case "$exit_code" in
  0 | 143) ;;
  *) fail "exporter exited with $exit_code after SIGTERM" ;;
esac

printf 'SMOKE PASS image=%s version=%s network=none\n' "$image" "$expected_version"
