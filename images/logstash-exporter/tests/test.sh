#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
nginx_index='docker.io/library/nginx:1.29-alpine@sha256:5616878291a2eed594aee8db4dade5878cf7edcb475e59193904b198d9b830de'
backend="verity-logstash-exporter-logstash-$$"
exporter="verity-logstash-exporter-exporter-$$"
orphan="verity-logstash-exporter-orphan-$$"
broken="verity-logstash-exporter-broken-$$"
network="verity-logstash-exporter-network-$$"
tmp=$(mktemp -d)

cleanup() {
  docker rm -f "$exporter" "$orphan" "$broken" "$backend" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

# wait_metrics CONTAINER OUTPUT LINE: poll the published 9198 port until the
# exporter serves /metrics containing the exact line LINE.
wait_metrics() {
  wm_port=$(docker port "$1" 9198/tcp | awk -F: 'NR == 1 { print $2 }')
  test -n "$wm_port" || fail "$1 did not publish port 9198"
  wm_attempts=0
  until curl --fail --silent --connect-timeout 1 --max-time 5 \
    "http://127.0.0.1:$wm_port/metrics" >"$2" 2>/dev/null &&
    grep -Fx "$3" "$2" >/dev/null; do
    wm_attempts=$((wm_attempts + 1))
    [ "$wm_attempts" -lt 30 ] || {
      docker logs "$1" >&2
      cat "$2" >&2 || true
      fail "$1 did not report '$3'"
    }
    sleep 1
  done
}

expect_metric() {
  grep -Fx "$2" "$1" >/dev/null || {
    cat "$1" >&2
    fail "metric line missing: $2"
  }
}

test "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532 ||
  fail 'image must run as UID 65532'
test "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/logstash-exporter"]' ||
  fail 'unexpected entrypoint'
docker run --rm "$image" --version >"$tmp/version" 2>&1 ||
  fail '--version failed'
grep -Ex 'v1\.9\.[0-9]+' "$tmp/version" >/dev/null || {
  cat "$tmp/version" >&2
  fail 'unexpected exporter version'
}

# A classic Docker image store cannot bind the index digest to a second
# platform's image, so pull the helper by its own per-platform child digest.
# The index bytes are verified against the pinned digest before a child is
# chosen, which keeps the pin authoritative.
image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
nginx_raw=$(docker buildx imagetools inspect --raw "$nginx_index") ||
  fail 'cannot inspect helper image index'
[ "sha256:$(printf '%s' "$nginx_raw" | sha256sum | cut -d' ' -f1)" = "${nginx_index#*@}" ] ||
  fail 'helper image index digest mismatch'
nginx_digest=$(printf '%s' "$nginx_raw" |
  jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') ||
  fail 'cannot resolve helper image digest'
case $nginx_digest in
  sha256:*) ;;
  *) fail "no unique linux/$image_arch helper image in $nginx_index" ;;
esac
nginx=docker.io/library/nginx@$nginx_digest
docker pull --quiet --platform "linux/$image_arch" "$nginx" >/dev/null ||
  fail 'cannot pull helper image'

# Fake Logstash monitoring API: GET / is the node info document and
# GET /_node/stats the node stats document, as served by Logstash on 9600.
# /broken answers 200 with a body that is not JSON.
mkdir -p "$tmp/api"
cat >"$tmp/api/node_info.json" <<'EOF'
{"host":"verity-logstash","version":"9.1.0","http_address":"0.0.0.0:9600","id":"8f3c2a64-5d1e-4b7a-9c0e-2f6a1b3d4e5f","name":"verity-logstash","ephemeral_id":"0b1c2d3e-4f50-6172-8394-a5b6c7d8e9f0","status":"green","snapshot":false,"pipeline":{"workers":3,"batch_size":125,"batch_delay":50},"build_date":"2025-01-01T00:00:00+00:00","build_sha":"0123456789abcdef0123456789abcdef01234567","build_snapshot":false}
EOF
cat >"$tmp/api/node_stats.json" <<'EOF'
{"host":"verity-logstash","version":"9.1.0","http_address":"0.0.0.0:9600","id":"8f3c2a64-5d1e-4b7a-9c0e-2f6a1b3d4e5f","name":"verity-logstash","status":"green",
"jvm":{"threads":{"count":42,"peak_count":51},"mem":{"heap_used_percent":17,"heap_committed_in_bytes":1073741824,"heap_max_in_bytes":1073741824,"heap_used_in_bytes":182536110,"non_heap_used_in_bytes":160000000,"non_heap_committed_in_bytes":170000000},"uptime_in_millis":123456},
"process":{"open_file_descriptors":108,"max_file_descriptors":1048576,"cpu":{"percent":3,"total_in_millis":98765},"mem":{"total_virtual_in_bytes":5000000000}},
"events":{"in":1234,"filtered":1230,"out":1229,"duration_in_millis":4321,"queue_push_duration_in_millis":12},
"reloads":{"successes":2,"failures":1},
"queue":{"events_count":0},
"pipelines":{"main":{"events":{"in":1234,"filtered":1230,"out":1229,"duration_in_millis":4321,"queue_push_duration_in_millis":12},
"plugins":{"inputs":[{"id":"verity_input","name":"generator","events":{"out":1234,"queue_push_duration_in_millis":12}}],"codecs":[],"filters":[{"id":"verity_filter","name":"mutate","events":{"in":1234,"out":1230,"duration_in_millis":99}}],"outputs":[{"id":"verity_output","name":"stdout","events":{"in":1230,"out":1229,"duration_in_millis":77}}]},
"reloads":{"successes":2,"failures":1,"last_success_timestamp":null,"last_failure_timestamp":null},
"queue":{"type":"memory","events_count":0,"queue_size_in_bytes":0,"max_queue_size_in_bytes":0}}}}
EOF
cat >"$tmp/default.conf" <<'EOF'
server {
  listen 9600;
  root /srv/api;
  default_type application/json;
  location = / {
    try_files /node_info.json =404;
  }
  location = /_node/stats {
    try_files /node_stats.json =404;
  }
  location /broken {
    default_type text/plain;
    return 200 'not a logstash api';
  }
}
EOF
chmod 755 "$tmp/api"
chmod 644 "$tmp/default.conf" "$tmp/api/node_info.json" "$tmp/api/node_stats.json"

docker network create --internal "$network" >/dev/null
docker run --name "$backend" -d --network "$network" --network-alias logstash \
  -v "$tmp/default.conf:/etc/nginx/conf.d/default.conf:ro" \
  -v "$tmp/api:/srv/api:ro" "$nginx" >/dev/null

attempts=0
until docker exec "$backend" wget -q -O - http://127.0.0.1:9600/_node/stats >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || {
    docker logs "$backend" >&2
    fail 'fake Logstash API did not become ready'
  }
  sleep 1
done

# An internal network cannot publish ports, so the exporter also joins the
# default bridge for the host-side scrape while it reaches Logstash only
# through the internal network alias.
docker create --name "$exporter" --read-only -p 127.0.0.1::9198 \
  -e LOGSTASH_URL=http://logstash:9600 "$image" >/dev/null
docker network connect "$network" "$exporter"
docker start "$exporter" >/dev/null
wait_metrics "$exporter" "$tmp/metrics" 'logstash_info_up 1'
port=$(docker port "$exporter" 9198/tcp | awk -F: 'NR == 1 { print $2 }')

expect_metric "$tmp/metrics" 'logstash_info_status{status="green"} 1'
expect_metric "$tmp/metrics" 'logstash_info_node{host="0.0.0.0:9600",http_address="verity-logstash",id="8f3c2a64-5d1e-4b7a-9c0e-2f6a1b3d4e5f",name="verity-logstash",version="9.1.0"} 1'
expect_metric "$tmp/metrics" 'logstash_info_pipeline_workers 3'
expect_metric "$tmp/metrics" 'logstash_info_pipeline_batch_size 125'
expect_metric "$tmp/metrics" 'logstash_stats_events_in 1234'
expect_metric "$tmp/metrics" 'logstash_stats_events_out 1229'
expect_metric "$tmp/metrics" 'logstash_stats_jvm_threads_count 42'
expect_metric "$tmp/metrics" 'logstash_stats_jvm_mem_heap_used_percent 17'
expect_metric "$tmp/metrics" 'logstash_stats_process_open_file_descriptors 108'
expect_metric "$tmp/metrics" 'logstash_stats_reload_failures 1'
expect_metric "$tmp/metrics" 'logstash_stats_pipeline_up{pipeline="main"} 1'
expect_metric "$tmp/metrics" 'logstash_stats_pipeline_events_filtered{pipeline="main"} 1230'
expect_metric "$tmp/metrics" 'logstash_stats_pipeline_plugin_events_in{pipeline="main",plugin="mutate",plugin_id="verity_filter",plugin_type="filter"} 1234'
expect_metric "$tmp/metrics" 'logstash_stats_pipeline_plugin_events_duration{pipeline="main",plugin="stdout",plugin_id="verity_output",plugin_type="output"} 77'
grep -E '^logstash_exporter_build_info\{.*version="1\.9\.[0-9]+"' "$tmp/metrics" >/dev/null ||
  fail 'logstash_exporter_build_info missing pinned version'

code=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 \
  "http://127.0.0.1:$port/healthcheck") || true
[ "$code" = 200 ] || fail "healthcheck with reachable Logstash returned $code"
curl --fail --silent --max-time 5 "http://127.0.0.1:$port/version" >"$tmp/version.json" ||
  fail '/version endpoint failed'
jq -e '.SemanticVersion | test("^v1\\.9\\.")' "$tmp/version.json" >/dev/null || {
  cat "$tmp/version.json" >&2
  fail '/version does not report the pinned version'
}

# An unreachable Logstash API must be reported as logstash_info_up 0 and a
# failing healthcheck while the exporter itself keeps serving.
docker create --name "$orphan" -p 127.0.0.1::9198 \
  -e LOGSTASH_URL=http://unreachable.invalid:9600 -e HTTP_TIMEOUT=1s "$image" >/dev/null
docker network connect "$network" "$orphan"
docker start "$orphan" >/dev/null
wait_metrics "$orphan" "$tmp/orphan.metrics" 'logstash_info_up 0'
if grep -E '^logstash_stats_events_in ' "$tmp/orphan.metrics" >/dev/null; then
  fail 'unreachable Logstash must not produce node stats'
fi
orphan_port=$(docker port "$orphan" 9198/tcp | awk -F: 'NR == 1 { print $2 }')
code=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 \
  "http://127.0.0.1:$orphan_port/healthcheck") || true
[ "$code" = 500 ] || fail "healthcheck with unreachable Logstash returned $code"

# A reachable endpoint that does not speak the Logstash API must also be up 0.
docker create --name "$broken" -p 127.0.0.1::9198 \
  -e LOGSTASH_URL=http://logstash:9600/broken "$image" >/dev/null
docker network connect "$network" "$broken"
docker start "$broken" >/dev/null
wait_metrics "$broken" "$tmp/broken.metrics" 'logstash_info_up 0'
if grep -E '^logstash_info_status' "$tmp/broken.metrics" >/dev/null; then
  fail 'non-JSON Logstash response must not produce node info'
fi

if docker run --rm "$image" --no-such-flag >"$tmp/invalid.log" 2>&1; then
  fail 'unknown flag unexpectedly succeeded'
fi
grep -F 'flag provided but not defined: -no-such-flag' "$tmp/invalid.log" >/dev/null ||
  fail 'unknown flag error missing'

if docker run --rm -e HTTP_TIMEOUT=soon "$image" >"$tmp/timeout.log" 2>&1; then
  fail 'invalid HTTP_TIMEOUT unexpectedly succeeded'
fi
grep -F 'failed to get http timeout' "$tmp/timeout.log" >/dev/null || {
  cat "$tmp/timeout.log" >&2
  fail 'invalid HTTP_TIMEOUT error missing'
}

if docker run --rm -e LOG_FORMAT=yaml "$image" >"$tmp/format.log" 2>&1; then
  fail 'invalid LOG_FORMAT unexpectedly succeeded'
fi
grep -F 'unknown log format' "$tmp/format.log" >/dev/null || {
  cat "$tmp/format.log" >&2
  fail 'invalid LOG_FORMAT error missing'
}

# The exporter installs no SIGTERM handler, so it must terminate promptly
# instead of waiting for the SIGKILL fallback (137). As PID 1 the kernel
# ignores the Go runtime's re-raised SIGTERM, so the runtime exits 2;
# otherwise the signal itself yields 128 + 15.
docker stop --timeout 10 "$exporter" >/dev/null
exit_code=$(docker inspect --format '{{.State.ExitCode}}' "$exporter")
case $exit_code in
  2 | 143) ;;
  *) fail "exporter exited $exit_code on SIGTERM, expected 2 or 143 (137 means SIGKILL)" ;;
esac

printf 'SMOKE PASS image=%s\n' "$image"
