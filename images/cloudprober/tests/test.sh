#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf '%s\n' 'package version not found' >&2; exit 1; }
container="verity-cloudprober-test-$$"
work=$(mktemp -d)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  docker logs "$container" >&2 2>&1 || true
  exit 1
}

user=$(docker image inspect -f '{{.Config.User}}' "$image")
[ "$user" = 65532 ] || fail "image user is $user, want 65532"
entrypoint=$(docker image inspect -f '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' "$image")
[ "$entrypoint" = '["/usr/bin/cloudprober"] null' ] || fail "unexpected entrypoint: $entrypoint"
[ "$(docker run --rm "$image" --version)" = "v$expected_version" ] ||
  fail "unexpected version, want v$expected_version"
if docker run --rm "$image" --no-such-flag >/dev/null 2>&1; then
  fail 'unknown flag was accepted'
fi

chmod 755 "$work"
# Probe the image's own HTTP server: one target that answers and one closed
# port that must fail.
cat >"$work/cloudprober.cfg" <<'EOF'
probe {
  name: "self_status"
  type: HTTP
  targets {
    host_names: "127.0.0.1"
  }
  http_probe {
    port: 9313
    relative_url: "/status"
  }
  interval_msec: 1000
  timeout_msec: 800
}
probe {
  name: "closed_port"
  type: HTTP
  targets {
    host_names: "127.0.0.1"
  }
  http_probe {
    port: 9
  }
  interval_msec: 1000
  timeout_msec: 800
}
EOF
printf 'probe {\n  name: "broken"\n  type: NOT_A_TYPE\n}\n' >"$work/invalid.cfg"
chmod 644 "$work/cloudprober.cfg" "$work/invalid.cfg"

docker run --rm -v "$work:/config:ro" "$image" \
  --config_file=/config/cloudprober.cfg --configtest >/dev/null 2>&1 ||
  fail 'valid config failed --configtest'
if docker run --rm -v "$work:/config:ro" "$image" \
  --config_file=/config/invalid.cfg --configtest >"$work/invalid.log" 2>&1; then
  fail 'invalid config passed --configtest'
fi
grep -F 'NOT_A_TYPE' "$work/invalid.log" >/dev/null || {
  cat "$work/invalid.log" >&2
  fail 'invalid config error does not name the bad value'
}

docker run -d --name "$container" --read-only -v "$work:/config:ro" -p 127.0.0.1::9313 \
  "$image" --config_file=/config/cloudprober.cfg --stop_time=1s >/dev/null
port=$(docker port "$container" 9313/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || fail 'no published host port'

metric() {
  # metric NAME PROBE: value of the counter for that probe, or empty.
  awk -v name="$1" -v probe="probe=\"$2\"" \
    'index($0, name "{") == 1 && index($0, probe) { print $2 }' "$work/metrics.txt" | sed -n 1p
}

attempts=0
while :; do
  attempts=$((attempts + 1))
  [ "$attempts" -le 30 ] || fail 'probe counters did not advance'
  sleep 1
  curl --fail --silent --connect-timeout 1 --max-time 5 \
    "http://127.0.0.1:$port/metrics" >"$work/metrics.txt" 2>/dev/null || continue
  success=$(metric success self_status)
  closed_total=$(metric total closed_port)
  [ -n "$success" ] && [ "$success" -ge 2 ] && [ -n "$closed_total" ] && [ "$closed_total" -ge 1 ] && break
done
[ "$(metric success closed_port)" = 0 ] || fail 'probe against a closed port reported success'
closed_failure=$(metric failure closed_port)
[ -n "$closed_failure" ] && [ "$closed_failure" -ge 1 ] ||
  fail 'probe against a closed port did not count a failure'
# The status surfacer lists probes only after its first refresh, which can lag
# the metrics endpoint by several seconds.
attempts=0
until curl --fail --silent --max-time 5 "http://127.0.0.1:$port/status" >"$work/status.html" 2>/dev/null &&
  grep -F 'self_status' "$work/status.html" >/dev/null; do
  attempts=$((attempts + 1))
  [ "$attempts" -le 30 ] || fail '/status does not list the configured probe'
  sleep 1
done

docker stop -t 15 "$container" >/dev/null
[ "$(docker inspect -f '{{.State.ExitCode}}' "$container")" = 0 ] ||
  fail 'cloudprober did not exit cleanly on SIGTERM'

printf '%s\n' "cloudprober $expected_version smoke test passed"
