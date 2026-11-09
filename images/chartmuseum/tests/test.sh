#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
container="verity-chartmuseum-test-$$"
workdir=$(mktemp -d)

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$workdir"
}
trap cleanup EXIT INT TERM

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65534 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/chartmuseum"]' ] \
  || fail 'unexpected entrypoint'
case $(docker image inspect -f '{{json .Config.Cmd}}' "$image") in null|'[]') ;; *) fail 'unexpected image command' ;; esac

version_output=$(docker run --rm --network none "$image" --version 2>&1) || fail 'chartmuseum --version failed'
printf '%s\n' "$version_output" | grep -F "ChartMuseum version $expected_version" >/dev/null \
  || fail "unexpected version output: $version_output"

# Negative: an unknown storage backend must fail with a readable error.
if output=$(docker run --rm --network none "$image" --port=8080 --storage=bogus 2>&1); then
  fail 'invalid storage backend unexpectedly succeeded'
fi
printf '%s\n' "$output" | grep -iF 'unsupported storage' >/dev/null \
  || fail "invalid storage backend was not reported: $output"

# Negative: a missing storage backend must fail with a readable error.
if output=$(docker run --rm --network none "$image" --port=8080 2>&1); then
  fail 'missing storage backend unexpectedly succeeded'
fi
printf '%s\n' "$output" | grep -iF 'storage' >/dev/null \
  || fail "missing storage backend was not reported: $output"

# Minimal Helm chart for the upload check.
chart="$workdir/smoke"
mkdir -p "$chart/templates"
cat >"$chart/Chart.yaml" <<'CHART'
apiVersion: v2
name: smoke
description: Smoke test chart
version: 0.1.0
CHART
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: smoke\n' >"$chart/templates/cm.yaml"
tar -C "$workdir" -czf "$workdir/smoke-0.1.0.tgz" smoke

docker run --name "$container" -d --read-only --user 65534 \
  --tmpfs /data:uid=65534,gid=65534 --tmpfs /tmp:uid=65534,gid=65534 \
  -p 127.0.0.1::8080 "$image" \
  --port=8080 --storage=local --storage-local-rootdir=/data >/dev/null
port=$(docker port "$container" 8080/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || { docker logs "$container" >&2 || true; fail 'no published port'; }

i=0
until response=$(curl --fail --silent --connect-timeout 1 --max-time 5 "http://127.0.0.1:$port/health"); do
  i=$((i + 1))
  [ "$i" -lt 30 ] || { docker logs "$container" >&2 || true; fail 'chartmuseum did not become ready'; }
  sleep 1
done
printf '%s' "$response" | grep -F '"healthy":true' >/dev/null \
  || fail "unexpected /health response: $response"

upload=$(curl --fail --silent --max-time 10 --data-binary "@$workdir/smoke-0.1.0.tgz" \
  "http://127.0.0.1:$port/api/charts") || { docker logs "$container" >&2 || true; fail 'chart upload failed'; }
printf '%s' "$upload" | grep -F '"saved":true' >/dev/null || fail "unexpected upload response: $upload"

charts=$(curl --fail --silent --max-time 10 "http://127.0.0.1:$port/api/charts") || fail 'chart listing failed'
printf '%s' "$charts" | grep -F '"smoke"' >/dev/null || fail "uploaded chart missing from /api/charts: $charts"

index=$(curl --fail --silent --max-time 10 "http://127.0.0.1:$port/index.yaml") || fail 'index.yaml failed'
printf '%s' "$index" | grep -F 'smoke-0.1.0.tgz' >/dev/null || fail "uploaded chart missing from index.yaml: $index"

# ChartMuseum has no graceful-shutdown handler and runs as PID 1, so SIGTERM ends it
# with the default signal disposition: 143, or 2 when the Go runtime falls back to
# exit(2) for a namespace init. A hung stop would show as 137 (SIGKILL).
docker stop --time 20 "$container" >/dev/null
exit_code=$(docker inspect -f '{{.State.ExitCode}}' "$container")
case $exit_code in
  0|2|143) ;;
  *) docker logs "$container" >&2 || true; fail "unexpected exit code after SIGTERM: $exit_code" ;;
esac

printf 'SMOKE PASS image=%s\n' "$image"
