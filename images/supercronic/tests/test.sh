#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
name="supercronic-smoke-$$"

cleanup() {
  docker rm -f "$name" "$name-drain" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  if [ -n "${2:-}" ] && [ -f "$2" ]; then
    sed 's/^/  | /' "$2" >&2
  fi
  exit 1
}

# wait_for_log CONTAINER FIXED_STRING SECONDS: poll container logs until the string appears.
wait_for_log() {
  i=0
  while [ "$i" -lt "$3" ]; do
    if docker logs "$1" 2>&1 | grep -F -- "$2" >/dev/null; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  return 1
}

# stop_gracefully CONTAINER LOG: send SIGTERM, require exit 0 within 10 seconds.
stop_gracefully() {
  docker kill --signal TERM "$1" >/dev/null || fail "could not signal $1"
  i=0
  while [ "$(docker inspect --format '{{.State.Running}}' "$1")" = true ]; do
    i=$((i + 1))
    [ "$i" -le 20 ] || fail "$1 did not exit within 10s of SIGTERM"
    sleep 0.5
  done
  docker logs "$1" >"$2" 2>&1
  status=$(docker inspect --format '{{.State.ExitCode}}' "$1")
  [ "$status" = 0 ] || fail "$1 exited with status $status after SIGTERM" "$2"
  grep -F 'msg="received terminated, shutting down"' "$2" >/dev/null ||
    fail "$1 did not log SIGTERM handling" "$2"
  grep -F 'level=info msg=exiting' "$2" >/dev/null || fail "$1 did not log a clean exit" "$2"
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/supercronic"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'

version=$(docker run --rm --network none --read-only "$image" -version) ||
  fail 'supercronic -version failed'
printf '%s\n' "$version" | grep -Ex '0\.2\.[0-9]+' >/dev/null ||
  fail "unexpected version output: $version"

# Negative: no crontab argument prints usage and exits 2.
set +e
docker run --rm --network none --read-only "$image" >"$work/noarg.log" 2>&1
status=$?
set -e
[ "$status" = 2 ] || fail "missing crontab argument exited $status, want 2" "$work/noarg.log"
grep -F 'Usage: /usr/bin/supercronic [OPTIONS] CRONTAB' "$work/noarg.log" >/dev/null ||
  fail 'missing crontab argument did not print usage' "$work/noarg.log"

# Crontabs are bind-mounted read-only; the image user must be able to read them.
chmod 0755 "$work"
cat >"$work/good.crontab" <<'EOF'
# Seconds-granularity schedule (7 fields) is a supercronic extension.
MARKER_PREFIX=verity
* * * * * * * echo "$MARKER_PREFIX-cron-marker uid=$(id -u)"
*/1 * * * * * * echo "verity-stderr-marker" >&2
* * * * * * * exit 3
EOF
printf '@fortnightly echo unknown-macro\n' >"$work/macro.crontab"
printf 'this is not a cron line\n' >"$work/bad.crontab"
printf '61 * * * * echo out-of-range\n' >"$work/range.crontab"
printf '* * * * * * * sleep 3; echo verity-drained-marker\n' >"$work/drain.crontab"
chmod 0644 "$work"/*.crontab

docker run --rm --network none --read-only -v "$work:/crontabs:ro" "$image" \
  -test /crontabs/good.crontab >"$work/test-good.log" 2>&1 ||
  fail '-test rejected a valid crontab' "$work/test-good.log"
grep -F 'msg="crontab is valid"' "$work/test-good.log" >/dev/null ||
  fail '-test did not report the crontab as valid' "$work/test-good.log"
if grep -F 'cron-marker' "$work/test-good.log" >/dev/null; then
  fail '-test ran a job' "$work/test-good.log"
fi

# Negative: malformed crontabs must fail -test with a diagnostic naming the line.
for bad in bad macro range; do
  if docker run --rm --network none --read-only -v "$work:/crontabs:ro" "$image" \
    -test "/crontabs/$bad.crontab" >"$work/test-$bad.log" 2>&1; then
    fail "-test accepted malformed crontab $bad" "$work/test-$bad.log"
  fi
  grep -F 'level=fatal msg="bad crontab line:' "$work/test-$bad.log" >/dev/null ||
    fail "-test did not diagnose malformed crontab $bad" "$work/test-$bad.log"
done
grep -F "'this is not a cron line'" "$work/test-bad.log" >/dev/null ||
  fail '-test diagnostic does not quote the offending line' "$work/test-bad.log"

# CRON_TZ schedules resolve against the shipped zoneinfo; an unknown zone is rejected.
printf 'CRON_TZ=America/New_York\n0 9 * * 1-5 echo weekday\n' >"$work/tz.crontab"
printf 'CRON_TZ=Nowhere/Bogus\n0 9 * * * echo never\n' >"$work/badtz.crontab"
chmod 0644 "$work/tz.crontab" "$work/badtz.crontab"
docker run --rm --network none --read-only -v "$work:/crontabs:ro" "$image" \
  -test /crontabs/tz.crontab >"$work/test-tz.log" 2>&1 ||
  fail '-test rejected a CRON_TZ crontab' "$work/test-tz.log"
grep -F 'msg="processes will be spawned using TZ: America/New_York"' "$work/test-tz.log" >/dev/null ||
  fail 'CRON_TZ was not loaded from zoneinfo' "$work/test-tz.log"
if docker run --rm --network none --read-only -v "$work:/crontabs:ro" "$image" \
  -test /crontabs/badtz.crontab >"$work/test-badtz.log" 2>&1; then
  fail '-test accepted an unknown CRON_TZ' "$work/test-badtz.log"
fi
grep -F 'level=fatal msg="unknown time zone Nowhere/Bogus"' "$work/test-badtz.log" >/dev/null ||
  fail 'unknown CRON_TZ was not diagnosed' "$work/test-badtz.log"

# Negative: a crontab path that does not exist must fail with the open error.
if docker run --rm --network none --read-only "$image" /crontabs/missing >"$work/missing.log" 2>&1; then
  fail 'missing crontab file unexpectedly succeeded' "$work/missing.log"
fi
grep -F 'open /crontabs/missing: no such file or directory' "$work/missing.log" >/dev/null ||
  fail 'missing crontab file was not reported' "$work/missing.log"

# Run the scheduler as PID 1 (default reaping mode) and assert jobs execute and are logged.
docker run -d --name "$name" --network none --read-only -v "$work:/crontabs:ro" "$image" \
  /crontabs/good.crontab >/dev/null || fail 'supercronic container failed to start'
wait_for_log "$name" 'iteration=2' 15 || {
  docker logs "$name" >"$work/run.log" 2>&1
  fail 'scheduler did not reach a third iteration within 15s' "$work/run.log"
}
stop_gracefully "$name" "$work/run.log"

grep -F 'msg="reaping dead processes"' "$work/run.log" >/dev/null ||
  fail 'supercronic did not enable reaping as PID 1' "$work/run.log"
# The logged job.command is the literal crontab text, not an expansion.
# shellcheck disable=SC2016
marker_command='job.command="echo \"$MARKER_PREFIX-cron-marker uid=$(id -u)\""'
grep -F 'msg="verity-cron-marker uid=65532" channel=stdout' "$work/run.log" |
  grep -F "$marker_command" |
  grep -F 'job.position=0' | grep -F 'job.schedule="* * * * * * *"' >/dev/null ||
  fail 'job stdout was not logged with crontab environment, channel and job fields' "$work/run.log"
grep -F 'msg="job succeeded"' "$work/run.log" | grep -F 'job.position=0' >/dev/null ||
  fail 'job success was not logged' "$work/run.log"
grep -F 'msg=verity-stderr-marker channel=stderr' "$work/run.log" | grep -F 'job.position=1' >/dev/null ||
  fail 'job stderr was not logged on the stderr channel' "$work/run.log"
grep -F 'level=error msg="error running command: exit status 3"' "$work/run.log" |
  grep -F 'job.position=2' >/dev/null ||
  fail 'failing job was not reported as an error' "$work/run.log"
marker_runs=$(grep -c 'msg="verity-cron-marker' "$work/run.log" || true)
[ "$marker_runs" -ge 3 ] || fail "seconds schedule ran $marker_runs times, want >= 3" "$work/run.log"

# JSON logging carries the same structured fields.
docker run -d --name "$name-drain" --network none --read-only -v "$work:/crontabs:ro" "$image" \
  -json /crontabs/drain.crontab >/dev/null || fail 'drain container failed to start'
wait_for_log "$name-drain" '"msg":"starting"' 10 || {
  docker logs "$name-drain" >"$work/drain.log" 2>&1
  fail 'drain job did not start within 10s' "$work/drain.log"
}
# SIGTERM while a job is running: supercronic must wait for it, then exit 0.
docker kill --signal TERM "$name-drain" >/dev/null || fail 'could not signal drain container'
i=0
while [ "$(docker inspect --format '{{.State.Running}}' "$name-drain")" = true ]; do
  i=$((i + 1))
  [ "$i" -le 20 ] || fail 'drain container did not exit within 10s of SIGTERM'
  sleep 0.5
done
docker logs "$name-drain" >"$work/drain.log" 2>&1
status=$(docker inspect --format '{{.State.ExitCode}}' "$name-drain")
[ "$status" = 0 ] || fail "drain container exited $status after SIGTERM" "$work/drain.log"
grep -F '"msg":"waiting for jobs to finish"' "$work/drain.log" >/dev/null ||
  fail 'shutdown did not wait for running jobs' "$work/drain.log"
grep -F '"channel":"stdout"' "$work/drain.log" | grep -F '"msg":"verity-drained-marker"' |
  grep -F '"job.position":0' >/dev/null ||
  fail 'running job was not allowed to finish before exit' "$work/drain.log"
drained_line=$(grep -n '"msg":"verity-drained-marker"' "$work/drain.log" | head -n 1 | cut -d: -f1)
exit_line=$(grep -n '"msg":"exiting"' "$work/drain.log" | cut -d: -f1)
[ -n "$exit_line" ] && [ "$drained_line" -lt "$exit_line" ] ||
  fail 'supercronic exited before the running job finished' "$work/drain.log"

printf 'SMOKE PASS image=%s\n' "$image"
