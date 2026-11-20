#!/bin/sh
# Smoke test for the ADOT Collector image. No AWS credentials are passed. It
# checks the upstream image contract, the stamped version, the bundled default
# configuration and /healthcheck probe, OTLP over gRPC and HTTP into a debug
# exporter, a clean SIGTERM shutdown, and rejection of invalid configurations.
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
label=verity.test=aws-otel-collector-$$
container="verity-aws-otel-collector-test-$$"
work=$(mktemp -d)

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -fv >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  docker logs "$container" >&2 2>&1 || true
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

expect() {
  grep -F -- "$2" "$1" >/dev/null || {
    cat "$1" >&2
    fail "$(basename "$1") lacks: $2"
  }
}

wait_healthy() {
  attempt=0
  until docker exec "$1" /healthcheck >"$work/healthcheck" 2>&1; do
    attempt=$((attempt + 1))
    [ "$(docker inspect --format '{{.State.Running}}' "$1")" = true ] ||
      fail "$1 exited before becoming healthy"
    [ "$attempt" -lt 60 ] || fail "$1 did not become healthy"
    sleep 1
  done
  expect "$work/healthcheck" 'STATUS: 200'
}

stop_cleanly() {
  docker stop --time 30 "$1" >/dev/null
  [ "$(docker inspect --format '{{.State.ExitCode}}' "$1")" = 0 ] ||
    fail "$1 did not exit cleanly on SIGTERM"
  docker logs "$1" >"$work/stopped" 2>&1
  expect "$work/stopped" 'Shutdown complete.'
}

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'

# OCI contract of public.ecr.aws/aws-observability/aws-otel-collector.
docker image inspect --format '{{.Config.User}}' "$image" | grep -Eqx '4317|aoc' ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/awscollector"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = \
  '["--config=/etc/otel-config.yaml"]' || fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = / ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" \
  >"$work/env"
grep -Fx 'RUN_IN_CONTAINER=True' "$work/env" >/dev/null || fail 'RUN_IN_CONTAINER=True is not set'
grep -Fx 'HOME=/home/aoc' "$work/env" >/dev/null || fail 'HOME=/home/aoc is not set'
if grep -E '^AWS_' "$work/env" >/dev/null; then
  fail 'the image bakes in AWS environment'
fi
if docker run --rm --network none --entrypoint /healthcheck "$image" -port 0 \
  >"$work/port0" 2>&1; then
  fail '/healthcheck accepted port 0'
fi
expect "$work/port0" 'port outside of range [1:65535]: 0'

# Upstream layout: binaries at /, default config at /etc/otel-config.yaml, and
# the ECS, EKS, and App Runner presets under /etc.
docker create --label "$label" --name "$container-layout" "$image" >/dev/null
docker export "$container-layout" | tar --numeric-owner -tvf - >"$work/layout"
docker rm "$container-layout" >/dev/null
for path in awscollector healthcheck; do
  grep -E "^-rwxr-xr-x .* $path\$" "$work/layout" >/dev/null || fail "missing executable /$path"
done
for path in etc/otel-config.yaml etc/ecs/ecs-default-config.yaml \
  etc/ecs/container-insights/otel-task-metrics-config.yaml etc/eks/prometheus/config-all.yaml \
  etc/apprunner/apprunner-default-config.yaml; do
  grep -E "^-rw-r--r-- .* $path\$" "$work/layout" >/dev/null || fail "missing file /$path"
done
grep -E '^drwxr-xr-x 4317/4317 .* home/aoc/?$' "$work/layout" >/dev/null ||
  fail '/home/aoc is not owned by aoc'
grep -E '^drwxrwxrwt .* tmp/?$' "$work/layout" >/dev/null || fail '/tmp is not 1777'

# The collector logs its stamped version before parsing flags; -help exits 1
# through the flag package, so only the output is asserted.
docker run --rm --network none "$image" --help >"$work/version" 2>&1 || true
expect "$work/version" "ADOT Collector version: v$expected_version"
expect "$work/version" '-config --config=file:'
printf 'version: %s\n' "$(grep -F 'ADOT Collector version' "$work/version")"

# (1) The bundled default config (OTLP, X-Ray, EMF) starts offline once a region
# is known and reports healthy through the upstream /healthcheck probe.
docker run -d --label "$label" --name "$container-default" --network none \
  -e AWS_REGION=us-west-2 "$image" >/dev/null
wait_healthy "$container-default"
docker logs "$container-default" >"$work/default" 2>&1
expect "$work/default" "ADOT Collector version: v$expected_version"
expect "$work/default" 'Everything is ready'
stop_cleanly "$container-default"
printf 'default config: healthy\n'

# (2) OTLP readiness with a credential-free config: gRPC and HTTP receivers into
# the debug exporter, with health_check published on all interfaces.
mkdir "$work/config"
cat >"$work/config/otlp.yaml" <<'YAML'
extensions:
  health_check:
    endpoint: 0.0.0.0:13133
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318
exporters:
  debug:
    verbosity: detailed
service:
  extensions: [health_check]
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [debug]
YAML
printf 'receivers:\n  nop:\nexporters:\n  debug:\nservice:\n  pipelines:\n    traces:\n      receivers: [nop]\n      exporters: [debug]\n' \
  >"$work/config/unknown.yaml"
printf 'receivers: [unterminated\n' >"$work/config/malformed.yaml"
chmod 0755 "$work/config"
chmod 0644 "$work/config/"*.yaml

docker run -d --label "$label" --name "$container" \
  -v "$work/config:/etc/verity:ro" \
  -p 127.0.0.1::4317 -p 127.0.0.1::4318 -p 127.0.0.1::13133 \
  "$image" --config=/etc/verity/otlp.yaml >/dev/null
wait_healthy "$container"
grpc=$(docker port "$container" 4317/tcp | awk -F: 'NR == 1 { print $NF }')
http=$(docker port "$container" 4318/tcp | awk -F: 'NR == 1 { print $NF }')
health=$(docker port "$container" 13133/tcp | awk -F: 'NR == 1 { print $NF }')
[ -n "$grpc" ] && [ -n "$http" ] && [ -n "$health" ] || fail 'collector ports were not published'

curl --fail --silent --show-error --max-time 5 "http://127.0.0.1:$health/" >"$work/health" ||
  fail 'health_check endpoint is unreachable'
expect "$work/health" '"status":"Server available"'

# An empty ExportTraceServiceRequest in one gRPC frame must return grpc-status 0.
printf '\000\000\000\000\000' | curl --silent --show-error --max-time 5 --http2-prior-knowledge \
  -H 'content-type: application/grpc' -H 'te: trailers' --data-binary @- -D "$work/grpc" -o /dev/null \
  "http://127.0.0.1:$grpc/opentelemetry.proto.collector.trace.v1.TraceService/Export" ||
  fail 'OTLP gRPC port 4317 is unreachable'
expect "$work/grpc" 'HTTP/2 200'
expect "$work/grpc" 'content-type: application/grpc'
expect "$work/grpc" 'grpc-status: 0'

curl --fail --silent --show-error --max-time 5 -H 'Content-Type: application/json' \
  -X POST "http://127.0.0.1:$http/v1/traces" \
  --data '{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"verity-smoke"}}]},"scopeSpans":[{"spans":[{"traceId":"5b8efff798038103d269b633813fc60c","spanId":"eee19b7ec3c1b174","name":"verity-span","kind":1,"startTimeUnixNano":"1700000000000000000","endTimeUnixNano":"1700000001000000000"}]}]}]}' \
  >/dev/null || fail 'OTLP HTTP export was rejected'
attempt=0
until docker logs "$container" 2>&1 | grep -F 'verity-span' >/dev/null; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 15 ] || fail 'OTLP span did not reach the debug exporter'
  sleep 1
done
stop_cleanly "$container"
printf 'otlp: grpc=%s http=%s health=%s\n' "$grpc" "$http" "$health"

# (3) Negative: /healthcheck fails when nothing listens, and invalid configs
# are rejected before the collector starts.
if docker run --rm --network none --entrypoint /healthcheck "$image" >"$work/unhealthy" 2>&1; then
  fail '/healthcheck succeeded without a running collector'
fi
expect "$work/unhealthy" 'unable to retrieve health status'
if docker run --rm --network none -v "$work/config:/etc/verity:ro" "$image" \
  --config=/etc/verity/unknown.yaml >"$work/unknown" 2>&1; then
  fail 'unknown receiver type unexpectedly accepted'
fi
expect "$work/unknown" "unknown type: \"nop\""
if docker run --rm --network none -v "$work/config:/etc/verity:ro" "$image" \
  --config=/etc/verity/malformed.yaml >"$work/malformed" 2>&1; then
  fail 'malformed config unexpectedly accepted'
fi
expect "$work/malformed" 'application run finished with error'
if docker run --rm --network none "$image" --config=/etc/verity/missing.yaml >"$work/missing" 2>&1; then
  fail 'missing config unexpectedly accepted'
fi
expect "$work/missing" 'missing.yaml'

printf 'SMOKE PASS image=%s\n' "$image"
