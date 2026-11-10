#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)"$/\1/p' \
  "$(dirname "$0")/../melange.yaml" | sed -n 1p)
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
container="verity-temporal-server-test-$$"
volume="verity-temporal-server-test-$$"
work=$(mktemp -d)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  docker logs "$container" >&2 2>&1 || true
  exit 1
}

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /var/lib/temporal ] ||
  fail 'unexpected OCI working directory'
[ "$(docker image inspect -f '{{json .Config.Cmd}}' "$image")" = '["/etc/temporal/entrypoint.sh"]' ] ||
  fail 'unexpected OCI command'

version=$(docker run --rm --network none "$image" temporal-server --version)
case "$version" in
  *"$expected_version"*) ;;
  *) fail "temporal-server version '$version' does not contain $expected_version" ;;
esac

# Negative: an unreadable configuration file exits non-zero with a readable error.
if docker run --rm --network none "$image" temporal-server --config-file /nonexistent/verity.yaml start \
  >"$work/badconfig.log" 2>&1; then
  fail 'start with a missing config file unexpectedly succeeded'
fi
grep -q 'could not read config file' "$work/badconfig.log" || {
  cat "$work/badconfig.log" >&2
  fail 'missing config file error is not readable'
}

start_server() {
  docker run --name "$container" -d --read-only --tmpfs /tmp:uid=65532,gid=65532 \
    -v "$volume:/var/lib/temporal" -e DB=sqlite -e BIND_ON_IP=0.0.0.0 \
    -p 127.0.0.1::7233 -p 127.0.0.1::7243 "$image" >/dev/null
  grpc_port=$(docker port "$container" 7233/tcp | awk -F: 'NR == 1 { print $NF }')
  http_port=$(docker port "$container" 7243/tcp | awk -F: 'NR == 1 { print $NF }')
  [ -n "$grpc_port" ] && [ -n "$http_port" ] || fail 'no published ports'
  base="http://127.0.0.1:$http_port"
  i=0
  until curl --fail --silent --max-time 5 "$base/api/v1/cluster-info" >"$work/cluster.json" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -lt 120 ] || fail 'temporal frontend never became ready on :7243'
    sleep 1
  done
}

printf '\0\0\0\0\0' >"$work/empty.bin"
start_server
grep -q "\"serverVersion\":\"$expected_version\"" "$work/cluster.json" || {
  cat "$work/cluster.json" >&2
  fail 'cluster-info does not report the expected server version'
}
grep -q '"persistenceStore":"sqlite"' "$work/cluster.json" || fail 'cluster-info does not report sqlite persistence'

# The frontend gRPC port answers the standard health check.
curl --silent --include --max-time 10 --http2-prior-knowledge -X POST \
  -H 'content-type: application/grpc' -H 'te: trailers' --data-binary "@$work/empty.bin" \
  "http://127.0.0.1:$grpc_port/grpc.health.v1.Health/Check" >"$work/health.txt" ||
  fail 'gRPC health check request failed'
grep -q 'grpc-status: 0' "$work/health.txt" || { cat -v "$work/health.txt" >&2; fail 'gRPC health check is not OK'; }

# Missing namespace is a readable 404.
status=$(curl --silent --output "$work/missing.json" --write-out '%{http_code}' --max-time 10 \
  "$base/api/v1/namespaces/verity-missing")
[ "$status" = 404 ] || fail "describing a missing namespace returned $status, want 404"
grep -q 'not found' "$work/missing.json" || fail 'missing namespace error is not readable'

# Register a namespace and start a workflow, which exercises frontend, history and matching.
status=$(curl --silent --output "$work/register.json" --write-out '%{http_code}' --max-time 10 \
  -X POST -H 'content-type: application/json' \
  -d '{"namespace":"verity","workflowExecutionRetentionPeriod":"86400s"}' "$base/api/v1/namespaces")
[ "$status" = 200 ] || { cat "$work/register.json" >&2; fail "namespace registration returned $status"; }
i=0
until curl --fail --silent --max-time 10 "$base/api/v1/namespaces/verity" >"$work/ns.json" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail 'registered namespace was never readable'
  sleep 1
done
grep -q 'NAMESPACE_STATE_REGISTERED' "$work/ns.json" || fail 'namespace is not registered'
status=$(curl --silent --output "$work/start.json" --write-out '%{http_code}' --max-time 20 \
  -X POST -H 'content-type: application/json' \
  -d '{"workflowType":{"name":"VerityWorkflow"},"taskQueue":{"name":"verity-tq"},"requestId":"verity-1"}' \
  "$base/api/v1/namespaces/verity/workflows/verity-wf-1")
[ "$status" = 200 ] || { cat "$work/start.json" >&2; fail "workflow start returned $status"; }
grep -q 'WORKFLOW_EXECUTION_STATUS_RUNNING' "$work/start.json" || fail 'started workflow is not running'

# SIGTERM stops the server cleanly.
docker stop -t 30 "$container" >/dev/null
[ "$(docker inspect -f '{{.State.ExitCode}}' "$container")" = 0 ] ||
  fail "server exited with $(docker inspect -f '{{.State.ExitCode}}' "$container") on SIGTERM"
docker rm "$container" >/dev/null

# Persistence: the namespace and the workflow survive a restart on the same volume.
start_server
curl --fail --silent --max-time 10 "$base/api/v1/namespaces/verity" >"$work/ns2.json" ||
  fail 'namespace did not survive a restart'
i=0
until curl --fail --silent --max-time 10 "$base/api/v1/namespaces/verity/workflows/verity-wf-1" \
  >"$work/describe.json" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail 'workflow did not survive a restart'
  sleep 1
done
grep -q 'WORKFLOW_EXECUTION_STATUS_RUNNING' "$work/describe.json" || fail 'workflow lost its state across a restart'

printf 'SMOKE PASS image=%s\n' "$image"
