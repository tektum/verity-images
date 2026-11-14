#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
recipe="$(dirname "$0")/../melange.yaml"
version=$(sed -n 's/^  version: "\([0-9.]*\)".*$/\1/p' "$recipe")
label="verity-test=node-problem-detector-$$"
work=$(mktemp -d)
container=verity-npd-smoke-$$

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -f >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ -n "$version" ] || fail 'could not read the recipe version'

# OCI contract: root like upstream (host /dev/kmsg and journal), upstream
# default monitors, upstream binary and config paths.
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 0 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/node-problem-detector"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = \
  '["--config.system-log-monitor=/config/kernel-monitor.json,/config/readonly-monitor.json"]' ||
  fail 'unexpected default command'

run() {
  docker run --rm --label "$label" --network none --read-only --cap-drop ALL \
    --security-opt no-new-privileges "$@"
}

# stdout only: docker prints a platform mismatch warning on stderr for emulated arm64 runs.
out=$(run "$image" --version) || fail 'version failed'
test "$out" = "v$version" || fail "version does not report v$version: $out"
out=$(run --entrypoint /node-problem-detector "$image" --version) ||
  fail 'upstream /node-problem-detector path failed'
test "$out" = "v$version" || fail "upstream path reports $out"

for path in /config/kernel-monitor.json /config/readonly-monitor.json \
  /config/custom-plugin-monitor.json /config/system-stats-monitor.json \
  /config/health-checker-kubelet.json /config/kernel-monitor-counter.json; do
  run --entrypoint /bin/sh "$image" -c "test -s $path" || fail "missing $path"
done
for path in /home/kubernetes/bin/health-checker /home/kubernetes/bin/log-counter \
  /config/plugin/check_ntp.sh /config/plugin/network_problem.sh; do
  run --entrypoint /bin/sh "$image" -c "test -x $path" || fail "missing executable $path"
done
run --entrypoint /home/kubernetes/bin/health-checker "$image" --help >"$work/hc.log" 2>&1 || true
grep -q -- '--component' "$work/hc.log" || fail "health-checker help: $(cat "$work/hc.log")"
run --entrypoint /home/kubernetes/bin/log-counter "$image" --help >"$work/lc.log" 2>&1 || true
grep -q -- '--journald-source' "$work/lc.log" || fail "log-counter help: $(cat "$work/lc.log")"
# The journald readers dlopen libsystemd; log-counter opens an (empty) journal.
run --tmpfs /journal --entrypoint /home/kubernetes/bin/log-counter "$image" \
  --journald-source=kernel --log-path=/journal --lookback=1m --delay=0s --count=1 \
  --pattern=verity >"$work/journal.log" 2>&1 ||
  fail "log-counter could not open a journal: $(cat "$work/journal.log")"

# Negative: an unknown flag is rejected.
if run "$image" --definitely-not-a-flag >"$work/bad.log" 2>&1; then
  fail 'unknown flag was accepted'
fi
grep -q 'unknown flag' "$work/bad.log" || fail "unexpected unknown-flag error: $(cat "$work/bad.log")"

# Custom plugin monitor fixture: the plugin reports a problem while
# /state/fail exists. It runs as a non-root user with no capabilities.
mkdir -p "$work/plugin" "$work/state"
cat >"$work/plugin/check_marker.sh" <<'SH'
#!/bin/bash
if [ -e /state/fail ]; then
  echo "marker present"
  exit 1
fi
echo "marker absent"
exit 0
SH
chmod 0755 "$work/plugin/check_marker.sh"
cat >"$work/plugin/monitor.json" <<'JSON'
{
  "plugin": "custom",
  "pluginConfig": {
    "invoke_interval": "1s",
    "timeout": "5s",
    "max_output_length": 80,
    "concurrency": 1
  },
  "source": "verity-smoke-plugin-monitor",
  "metricsReporting": true,
  "conditions": [
    {
      "type": "VeritySmokeProblem",
      "reason": "MarkerAbsent",
      "message": "marker is absent"
    }
  ],
  "rules": [
    {
      "type": "temporary",
      "reason": "MarkerPresentTemporary",
      "path": "/plugin/check_marker.sh",
      "timeout": "3s"
    },
    {
      "type": "permanent",
      "condition": "VeritySmokeProblem",
      "reason": "MarkerPresent",
      "path": "/plugin/check_marker.sh",
      "timeout": "3s"
    }
  ]
}
JSON
chmod -R a+rX "$work/plugin"
chmod 0777 "$work/state"

# Negative: the default Kubernetes exporter needs a cluster and stops the daemon.
if run -v "$work/plugin:/plugin:ro" "$image" \
  --config.custom-plugin-monitor=/plugin/monitor.json >"$work/k8s.log" 2>&1; then
  fail 'started without a cluster while the Kubernetes exporter is enabled'
fi
grep -Eqi 'kube|in-cluster|apiserver' "$work/k8s.log" ||
  fail "unexpected Kubernetes exporter error: $(cat "$work/k8s.log")"

# Negative: a monitor config that cannot be read stops the daemon.
if run "$image" --enable-k8s-exporter=false \
  --config.custom-plugin-monitor=/plugin/missing.json >"$work/missing.log" 2>&1; then
  fail 'started with an unreadable monitor config'
fi
grep -q 'Failed to read configuration file "/plugin/missing.json"' "$work/missing.log" ||
  fail "unexpected missing-config error: $(cat "$work/missing.log")"

docker run -d --name "$container" --label "$label" --network none --read-only \
  --cap-drop ALL --security-opt no-new-privileges --user 65532:65532 \
  -v "$work/plugin:/plugin:ro" -v "$work/state:/state" "$image" \
  --enable-k8s-exporter=false --config.custom-plugin-monitor=/plugin/monitor.json \
  --prometheus-address=127.0.0.1 --prometheus-port=20257 >/dev/null

# The image has no HTTP client (Wolfi busybox drops wget); bash, shipped for the
# shell plugins, speaks HTTP/1.0 over /dev/tcp inside the network-less container.
metrics() {
  docker exec "$container" bash -c 'exec 3<>/dev/tcp/127.0.0.1/20257 &&
    printf "GET /metrics HTTP/1.0\r\nHost: localhost\r\n\r\n" >&3 && cat <&3' 2>/dev/null |
    tr -d '\r'
}
gauge() {
  metrics | sed -n "s/^problem_gauge{\(.*\)} \([0-9.e+]*\)\$/\1 \2/p" |
    grep 'reason="MarkerPresent"' | grep 'type="VeritySmokeProblem"' | awk '{print $NF}'
}
counter() {
  metrics | sed -n 's/^problem_counter{\(.*\)} \([0-9.e+]*\)$/\1 \2/p' |
    grep 'reason="MarkerPresentTemporary"' | awk '{print $NF}'
}
wait_for() {
  what=$1
  want=$2
  attempts=0
  until [ "$($what)" = "$want" ]; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 60 ] || {
      docker logs "$container" >&2 || true
      metrics | grep -E '^problem_' >&2 || true
      fail "$what did not reach $want"
    }
    sleep 1
  done
}

# /healthz belongs to the Kubernetes exporter, which is off here; readiness is
# the Prometheus endpoint exporting the plugin monitor's condition.
attempts=0
until metrics >"$work/metrics" && grep -q '^problem_gauge{' "$work/metrics"; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || {
    docker logs "$container" >&2 || true
    fail 'metrics endpoint did not become ready'
  }
  sleep 1
done

# Healthy plugin: the permanent condition is clear.
wait_for gauge 0

# Plugin reports the problem: the condition is set and the temporary problem counts.
: >"$work/state/fail"
wait_for gauge 1
attempts=0
until c=$(counter) && [ -n "$c" ] && [ "${c%%.*}" -ge 1 ]; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || fail "temporary problem was not counted: ${c:-none}"
  sleep 1
done
docker logs "$container" 2>&1 | grep -q 'MarkerPresent' ||
  fail 'condition change was not logged'

# Recovery clears the condition again.
rm -f "$work/state/fail"
wait_for gauge 0

printf 'SMOKE PASS image=%s\n' "$image"
