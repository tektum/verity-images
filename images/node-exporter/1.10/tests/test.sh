#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
fixture='docker.io/curlimages/curl:8.14.1@sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b'
container="verity-node-exporter-test-$$"
work=$(mktemp -d)

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  chmod 755 "$work/blocked" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

curl_metrics() {
  docker run --rm --network "container:$container" "$fixture" \
    --fail --silent --show-error http://127.0.0.1:9100/metrics
}

start_exporter() {
  if [ "${1:-}" = --blocked-sysfs ]; then
    shift
    docker run --name "$container" -d --read-only \
      -v "$work/blocked:/blocked:ro" "$image" \
      --web.listen-address=0.0.0.0:9100 "$@" >/dev/null
  else
    docker run --name "$container" -d --read-only "$image" \
      --web.listen-address=0.0.0.0:9100 "$@" >/dev/null
  fi

  i=0
  until curl_metrics >/dev/null 2>&1; do
    [ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ] || {
      docker logs "$container" >&2
      fail 'node_exporter exited before becoming ready'
    }
    i=$((i + 1))
    [ "$i" -lt 20 ] || {
      docker logs "$container" >&2
      fail 'node_exporter did not become ready'
    }
    sleep 1
  done
}

stop_exporter() {
  docker rm -f "$container" >/dev/null
}

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] || fail 'image user is not 65532'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/bin/node_exporter"]' ] || fail 'unexpected image entrypoint'
docker run --rm "$image" --version 2>&1 | grep -F 'version 1.10.2' >/dev/null || fail 'node_exporter version check failed'

start_exporter --collector.disable-defaults --collector.cpu --collector.netclass
metrics=$(curl_metrics)
printf '%s\n' "$metrics" | grep -q '^node_cpu_seconds_total{' || fail 'cpu collector did not expose metrics'
printf '%s\n' "$metrics" | grep -q '^node_network_info{' || fail 'netclass collector did not expose metrics'
stop_exporter

if missing_proc=$(docker run --rm "$image" --collector.disable-defaults \
  --collector.cpu --path.procfs=/missing-proc 2>&1); then
  fail 'node_exporter started with a missing procfs path'
fi
printf '%s\n' "$missing_proc" | grep -Fq 'failed to open procfs' \
  || fail 'missing procfs failure did not identify the invalid path'

mkdir "$work/blocked"
chmod 000 "$work/blocked"
start_exporter --blocked-sysfs \
  --collector.disable-defaults --collector.netclass --path.sysfs=/blocked
metrics=$(curl_metrics)
printf '%s\n' "$metrics" | grep -Fq 'node_scrape_collector_success{collector="netclass"} 0' \
  || fail 'inaccessible sysfs did not fail the netclass collector'
if printf '%s\n' "$metrics" | grep -q '^node_network_info{'; then
  fail 'network metrics were exposed from an inaccessible sysfs path'
fi

printf 'SMOKE PASS image=%s\n' "$image"
