#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
version=$(sed -n 's/^  version: "\([0-9.]*\)".*/\1/p' "$here/../melange.yaml")
work=$(mktemp -d)
suffix="$$-$(date +%s)"
net="otel-cli-smoke-$suffix"
grpc="otel-cli-grpc-$suffix"
http="otel-cli-http-$suffix"
spool="otel-cli-spool-$suffix"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  docker rm -f "$grpc" "$http" >/dev/null 2>&1 || true
  docker volume rm "$spool" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail 'could not read the pinned otel-cli version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/otel-cli"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'

# Every container is unprivileged on a read-only root with no capabilities.
run() {
  docker run --rm --read-only --cap-drop=ALL "$@"
}

run --network none "$image" --help >"$work/help" 2>&1 || fail "help failed: $(cat "$work/help")"
for command in span exec status server; do
  grep -Eq "^  $command " "$work/help" || fail "help does not list the $command command"
done

status=0
run --network none "$image" --definitely-invalid >"$work/invalid" 2>&1 || status=$?
test "$status" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"

# Without an endpoint otel-cli is a documented silent no-op, even with --fail,
# so instrumented scripts keep working when no collector is configured.
run --network none "$image" span --name noop --fail --tp-print >"$work/noop" 2>&1 ||
  fail "span without endpoint failed: $(cat "$work/noop")"
grep -Fx 'TRACEPARENT=00-00000000000000000000000000000000-0000000000000000-00' "$work/noop" >/dev/null ||
  fail "span without endpoint did not report an empty traceparent: $(cat "$work/noop")"

# The https receiver is unsupported upstream and must refuse to start.
status=0
run --network none "$image" server json --endpoint https://0.0.0.0:4318 --fail --verbose \
  >"$work/https-server" 2>&1 || status=$?
test "$status" -ne 0 || fail 'https server unexpectedly started'
grep -F 'https server is not supported' "$work/https-server" >/dev/null ||
  fail "https server diagnostic is missing: $(cat "$work/https-server")"

# Receivers: the image's own `server json` mode in separate containers on an
# internal network without egress. The gRPC receiver writes one
# <trace>/<span>/span.json per span to /tmp, a fresh volume that inherits the
# image's nonroot-owned /tmp, and exits after three spans.
docker network create --internal "$net" >/dev/null
docker volume create "$spool" >/dev/null
docker run -d --name "$grpc" --network "$net" --read-only --cap-drop=ALL \
  -v "$spool:/tmp" "$image" \
  server json --endpoint 0.0.0.0:4317 --dir /tmp --max-spans 3 --verbose >/dev/null
docker run -d --name "$http" --network "$net" --read-only --cap-drop=ALL "$image" \
  server json --endpoint http://0.0.0.0:4318 --stdout --max-spans 1 --verbose >/dev/null

client() {
  run --network "$net" "$@"
}

# Retry until the receiver listens. Forced ids make a retry idempotent: the
# receiver writes the same file again.
send_until_ready() {
  out=$1
  shift
  attempt=0
  until client "$image" "$@" >"$out" 2>&1; do
    # Only a receiver that is not resolvable or listening yet is retried.
    grep -E 'connection refused|server misbehaving|no such host' "$out" >/dev/null ||
      fail "span was rejected: $(cat "$out")"
    attempt=$((attempt + 1))
    [ "$attempt" -lt 30 ] || fail "span was never accepted: $(cat "$out")"
    sleep 1
  done
}

# b64hex BASE64 prints the lowercase hex of a protobuf-JSON id.
b64hex() {
  printf '%s' "$1" | base64 -d | od -An -v -tx1 | tr -d ' \n'
}

trace_id=4f54454c2d434c492d534d4f4b452d31
span_id=0102030405060708
send_until_ready "$work/span" span \
  --endpoint "$grpc:4317" --insecure --fail --verbose --timeout 5s \
  --force-trace-id "$trace_id" --force-span-id "$span_id" \
  --service smoke-service --name smoke-span --kind server \
  --attrs 'smoke.key=smoke-value,smoke.count=42' \
  --status-code error --status-description smoke-failure \
  --start 2023-11-14T22:13:20.25Z --end 2023-11-14T22:13:21.5Z --tp-print
grep -Fx "TRACEPARENT=00-$trace_id-$span_id-01" "$work/span" >/dev/null ||
  fail "client did not print the sent traceparent: $(cat "$work/span")"

# Negative cases, while the receiver is up, so each failure is the client's own.
expect_failure() {
  label=$1
  diagnostic=$2
  shift 2
  status=0
  client "$@" >"$work/negative" 2>&1 || status=$?
  test "$status" -ne 0 || fail "$label unexpectedly succeeded"
  grep -F -- "$diagnostic" "$work/negative" >/dev/null ||
    fail "$label diagnostic is missing: $(cat "$work/negative")"
}
common="--endpoint $grpc:4317 --insecure --fail --verbose --timeout 3s --name rejected"
# shellcheck disable=SC2086 # $common is a fixed word list
{
  expect_failure 'closed port' 'connection refused' "$image" span \
    --endpoint "$grpc:4999" --insecure --fail --verbose --timeout 3s --name rejected
  expect_failure 'missing required traceparent' 'failed to find a valid traceparent' \
    "$image" span $common --tp-required
  expect_failure 'malformed required traceparent' 'failed to find a valid traceparent' \
    -e TRACEPARENT=00-not-a-traceparent-01 "$image" span $common --tp-required
  expect_failure 'invalid trace id' 'error parsing hex string' \
    "$image" span $common --force-trace-id not-hex
  expect_failure 'invalid attribute' 'must be formatted as key=value' \
    "$image" span $common --attrs novalue
  expect_failure 'invalid start time' 'could not parse span start time' \
    "$image" span $common --start yesterday
}

# exec wraps a command in a span and injects TRACEPARENT, so a nested span,
# configured only through OTEL_* variables, becomes its child.
exec_trace=4f54454c2d434c492d534d4f4b452d32
exec_span=1112131415161718
client -e OTEL_EXPORTER_OTLP_ENDPOINT="$grpc:4317" -e OTEL_EXPORTER_OTLP_INSECURE=true \
  -e OTEL_CLI_FAIL=true -e OTEL_CLI_VERBOSE=true "$image" exec \
  --force-trace-id "$exec_trace" --force-span-id "$exec_span" --name smoke-exec --timeout 5s -- \
  /usr/bin/otel-cli span --name smoke-child --kind internal --timeout 5s --tp-print \
  >"$work/exec" 2>&1 || fail "exec failed: $(cat "$work/exec")"
child_span=$(sed -n "s/^TRACEPARENT=00-$exec_trace-\([0-9a-f]\{16\}\)-01$/\1/p" "$work/exec")
[ -n "$child_span" ] || fail "child span did not inherit the exec trace: $(cat "$work/exec")"

status=$(timeout 60 docker wait "$grpc") ||
  fail "gRPC receiver did not receive three spans: $(docker logs "$grpc" 2>&1)"
test "$status" = 0 || fail "gRPC receiver exited $status: $(docker logs "$grpc" 2>&1)"
docker cp "$grpc:/tmp/." "$work/grpc-out" >/dev/null 2>&1 ||
  fail 'could not copy the gRPC receiver output'
find "$work/grpc-out" -name span.json >"$work/files"
test "$(wc -l <"$work/files")" -eq 3 ||
  fail "gRPC receiver stored unexpected spans: $(cat "$work/files")"

span_json() {
  file="$work/grpc-out/$1/$2/span.json"
  [ -f "$file" ] || fail "receiver has no span $1/$2: $(cat "$work/files")"
  cat "$file"
}

span_json "$trace_id" "$span_id" >"$work/received"
test "$(b64hex "$(jq -r .trace_id "$work/received")")" = "$trace_id" || fail 'trace id mismatch'
test "$(b64hex "$(jq -r .span_id "$work/received")")" = "$span_id" || fail 'span id mismatch'
jq -e '.name == "smoke-span" and .kind == 2' "$work/received" >/dev/null ||
  fail "span name or server kind mismatch: $(cat "$work/received")"
jq -e '.start_time_unix_nano == 1700000000250000000 and .end_time_unix_nano == 1700000001500000000' \
  "$work/received" >/dev/null || fail "span timestamps mismatch: $(cat "$work/received")"
jq -e '.status.code == 2 and .status.message == "smoke-failure"' "$work/received" >/dev/null ||
  fail "span status mismatch: $(cat "$work/received")"
jq -e '[.attributes[] | {(.key): .value.Value}] | add
  | .["smoke.key"].StringValue == "smoke-value" and .["smoke.count"].IntValue == 42' \
  "$work/received" >/dev/null || fail "span attributes mismatch: $(cat "$work/received")"
jq -e '(.parent_span_id // "") == ""' "$work/received" >/dev/null ||
  fail "root span has a parent: $(cat "$work/received")"

span_json "$exec_trace" "$exec_span" >"$work/exec-received"
jq -e '.name == "smoke-exec" and .kind == 3' "$work/exec-received" >/dev/null ||
  fail "exec span name or client kind mismatch: $(cat "$work/exec-received")"
jq -e '[.attributes[] | {(.key): .value.Value.StringValue}] | add
  | .["process.command"] == "/usr/bin/otel-cli"' "$work/exec-received" >/dev/null ||
  fail "exec span lacks the process.command attribute: $(cat "$work/exec-received")"

span_json "$exec_trace" "$child_span" >"$work/child-received"
jq -e '.name == "smoke-child" and .kind == 1' "$work/child-received" >/dev/null ||
  fail "child span name or internal kind mismatch: $(cat "$work/child-received")"
test "$(b64hex "$(jq -r .parent_span_id "$work/child-received")")" = "$exec_span" ||
  fail "child span is not parented to the exec span: $(cat "$work/child-received")"

# OTLP/HTTP: the second receiver prints the span as one JSON line and exits.
# Upstream's HTTP receiver answers without a Content-Type, which the upstream
# client reports under --fail after the span was delivered; that exact
# diagnostic counts as delivery and the receiver output below proves it.
http_trace=4f54454c2d434c492d534d4f4b452d33
http_span=2122232425262728
attempt=0
until client "$image" span \
  --endpoint "http://$http:4318" --protocol http/protobuf --fail --verbose --timeout 5s \
  --force-trace-id "$http_trace" --force-span-id "$http_span" \
  --name smoke-http --kind producer --attrs "otel-cli.version=$version" \
  >"$work/http-span" 2>&1; do
  grep -F 'server is out of specification: Content-Type header is missing' \
    "$work/http-span" >/dev/null && break
  grep -E 'connection refused|server misbehaving|no such host' "$work/http-span" >/dev/null ||
    fail "HTTP span was rejected: $(cat "$work/http-span")"
  attempt=$((attempt + 1))
  [ "$attempt" -lt 30 ] || fail "HTTP span was never accepted: $(cat "$work/http-span")"
  sleep 1
done
# After --max-spans the upstream HTTP receiver reports its own shutdown as a
# serve error and exits 1; any other exit or diagnostic is a failure.
status=$(timeout 60 docker wait "$http") ||
  fail "HTTP receiver did not receive its span: $(docker logs "$http" 2>&1)"
docker logs "$http" 2>"$work/http-stderr" >"$work/http-stdout"
case "$status" in
  0) ;;
  1) closed='failed to serve: http: Server closed$'
     if ! grep -Eq "$closed" "$work/http-stderr" || grep -Ev "$closed" "$work/http-stderr" >/dev/null; then
       fail "HTTP receiver failed: $(cat "$work/http-stderr")"
     fi ;;
  *) fail "HTTP receiver exited $status: $(cat "$work/http-stderr")" ;;
esac
jq -s -e --arg v "$version" 'length == 1 and (.[0]
  | .name == "smoke-http" and .kind == 4
  and ([.attributes[] | {(.key): .value.Value.StringValue}] | add | .["otel-cli.version"] == $v))' \
  "$work/http-stdout" >/dev/null || fail "HTTP receiver output mismatch: $(cat "$work/http-stdout")"
test "$(b64hex "$(jq -r .trace_id "$work/http-stdout")")" = "$http_trace" ||
  fail 'HTTP span trace id mismatch'

echo 'SMOKE PASS'
