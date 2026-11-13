#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
config="$(dirname "$0")/../apko.yaml"
version=$(sed -n 's/^    - collectd=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
work=$(mktemp -d)
containers=

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  for c in $containers; do
    docker rm -f -v "$c" >/dev/null 2>&1 || true
  done
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail 'could not read the pinned collectd version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/collectd","-f"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = \
  '["-C","/etc/collectd/collectd.conf"]' || fail 'unexpected cmd'

# `-h` prints the build banner. The Wolfi package is built from the
# collectd-5.12.0 tag plus cherry-picks, so git-describe may add `.N.gSHA`.
docker run --rm --network none "$image" -h >"$work/help" 2>&1 || fail "help failed: $(cat "$work/help")"
grep -E "^collectd $(printf '%s' "$version" | sed 's/\./\\./g')(\.[0-9]+\.g[0-9a-f]+)?, http://collectd\.org/$" \
  "$work/help" >/dev/null || fail "help does not report collectd $version: $(cat "$work/help")"

chmod 755 "$work"

# Test config: real read plugins, csv and unixsock writers, logs on stderr.
# Hostname is fixed and FQDNLookup is off so it runs with --network none.
cat >"$work/collectd.conf" <<'EOF'
Hostname "verity-test"
FQDNLookup false
Interval 1
LoadPlugin logfile
<Plugin logfile>
  LogLevel info
  File STDERR
  Timestamp false
</Plugin>
LoadPlugin cpu
LoadPlugin load
LoadPlugin memory
LoadPlugin csv
<Plugin csv>
  DataDir "/var/lib/collectd/csv"
  StoreRates true
</Plugin>
LoadPlugin unixsock
<Plugin unixsock>
  SocketFile "/tmp/collectd.sock"
  SocketGroup "nonroot"
  SocketPerms "0660"
</Plugin>
EOF
printf '<Plugin cpu\n' >"$work/syntax.conf"
printf 'FQDNLookup false\nLoadPlugin verity_no_such_plugin\n' >"$work/plugin.conf"
chmod 644 "$work"/*.conf

# Config validation. collectd 5.12.0 exits 0 on `-t` before it reads the
# config (src/daemon/collectd.c init_config(); fixed on upstream main only),
# so `-t` cannot reject anything in this release. `-T` parses the config,
# loads and initialises every plugin, runs one read cycle and exits, which is
# the effective check. If this `-t` assertion starts failing, Wolfi shipped the
# fix: switch the checks below to `-t`.
docker run --rm --network none -v "$work/syntax.conf:/c.conf:ro" "$image" -t -C /c.conf \
  >"$work/t.out" 2>&1 || fail "collectd -t now validates configs; use it: $(cat "$work/t.out")"

docker run --rm --network none -v "$work/collectd.conf:/c.conf:ro" "$image" -T -C /c.conf \
  >"$work/check.out" 2>&1 || fail "valid config rejected: $(cat "$work/check.out")"
grep -Fx 'Exiting normally.' "$work/check.out" >/dev/null ||
  fail "valid config did not complete a read cycle: $(cat "$work/check.out")"
for p in cpu load memory csv unixsock; do
  grep -F "plugin \"$p\" successfully loaded." "$work/check.out" >/dev/null ||
    fail "plugin $p did not load: $(cat "$work/check.out")"
done

rc=0
docker run --rm --network none -v "$work/syntax.conf:/c.conf:ro" "$image" -T -C /c.conf \
  >"$work/syntax.out" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'config with a syntax error unexpectedly passed'
grep -F "Parse error in file \`/c.conf', line 2" "$work/syntax.out" >/dev/null ||
  fail "syntax error diagnostic is missing: $(cat "$work/syntax.out")"
grep -F 'Error: Parsing the config file failed!' "$work/syntax.out" >/dev/null ||
  fail "syntax error summary is missing: $(cat "$work/syntax.out")"

rc=0
docker run --rm --network none -v "$work/plugin.conf:/c.conf:ro" "$image" -T -C /c.conf \
  >"$work/plugin.out" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'config loading an unknown plugin unexpectedly passed'
grep -F 'Could not find plugin "verity_no_such_plugin" in /usr/lib/collectd' "$work/plugin.out" >/dev/null ||
  fail "unknown plugin diagnostic is missing: $(cat "$work/plugin.out")"

# copy_out CONTAINER PATH DEST: copy a path out of a (running or stopped)
# container. The image has no shell, so files are read through docker cp.
copy_out() {
  rm -rf "$3"
  docker cp "$1:$2" "$3" >/dev/null 2>&1
}

# numeric_rows FILE: count data rows whose every field is a number.
numeric_rows() {
  sed 1d "$1" | grep -cE '^[0-9]+(\.[0-9]+)?(,[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?)+$' || true
}

# Daemon run: read-only rootfs, no capabilities, no network. /var/lib/collectd
# is an anonymous volume seeded from the image (owned by 65532).
name="collectd-smoke-$$"
containers="$containers $name"
docker run -d --name "$name" --network none --read-only --cap-drop=ALL \
  --tmpfs /tmp:mode=1777 -v /var/lib/collectd \
  -v "$work/collectd.conf:/etc/verity/collectd.conf:ro" \
  "$image" -C /etc/verity/collectd.conf >/dev/null || fail 'daemon did not start'

csv="$work/csv"
attempt=0
load_rows() {
  cat "$csv"/verity-test/load/load-* 2>/dev/null | numeric_rows /dev/stdin
}
until [ -d "$csv/verity-test/memory" ] && [ "$(load_rows)" -ge 3 ]; do
  attempt=$((attempt + 1))
  if [ "$attempt" -gt 30 ]; then
    fail "no load metrics within 30s: $(docker logs "$name" 2>&1)"
  fi
  test "$(docker inspect --format '{{.State.Running}}' "$name")" = true ||
    fail "daemon exited early: $(docker logs "$name" 2>&1)"
  sleep 1
  copy_out "$name" /var/lib/collectd/csv "$csv" || true
done

head -n 1 "$csv"/verity-test/load/load-* | grep -Fx 'epoch,shortterm,midterm,longterm' >/dev/null ||
  fail "unexpected load csv header: $(head -n 1 "$csv"/verity-test/load/load-*)"
cat "$csv"/verity-test/memory/memory-used-* >"$work/mem.csv"
test "$(numeric_rows "$work/mem.csv")" -ge 1 || fail "no numeric memory rows: $(cat "$work/mem.csv")"
awk -F, 'NR > 1 && $2 > 0 { ok = 1 } END { exit !ok }' "$work/mem.csv" ||
  fail "memory used is never positive: $(cat "$work/mem.csv")"
ls "$csv"/verity-test/cpu-0/cpu-idle-* >/dev/null 2>&1 ||
  fail "cpu plugin wrote no cpu-0 idle series: $(ls -R "$csv")"

# The same values over the unixsock control socket.
docker exec "$name" collectdctl -s /tmp/collectd.sock listval >"$work/listval" 2>&1 ||
  fail "collectdctl listval failed: $(cat "$work/listval")"
for id in verity-test/load/load verity-test/memory/memory-used verity-test/cpu-0/cpu-idle; do
  grep -Fx "$id" "$work/listval" >/dev/null || fail "listval lacks $id: $(cat "$work/listval")"
done
docker exec "$name" collectdctl -s /tmp/collectd.sock getval verity-test/load/load >"$work/getval" 2>&1 ||
  fail "collectdctl getval failed: $(cat "$work/getval")"
for f in shortterm midterm longterm; do
  grep -E "^$f=[0-9]+(\.[0-9]+)?(e[-+][0-9]+)?$" "$work/getval" >/dev/null ||
    fail "getval lacks a numeric $f: $(cat "$work/getval")"
done
rc=0
docker exec "$name" collectdctl -s /tmp/collectd.sock getval verity-test/verity/missing \
  >"$work/getval-missing" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'getval of an unknown identifier unexpectedly succeeded'

# SIGTERM stops the foreground daemon cleanly and promptly.
docker kill --signal TERM "$name" >/dev/null || fail 'could not signal the daemon'
attempt=0
while [ "$(docker inspect --format '{{.State.Running}}' "$name")" = true ]; do
  attempt=$((attempt + 1))
  [ "$attempt" -le 20 ] || fail 'daemon ignored SIGTERM for 10s'
  sleep 0.5
done
test "$(docker inspect --format '{{.State.ExitCode}}' "$name")" = 0 ||
  fail "daemon exited non-zero on SIGTERM: $(docker logs "$name" 2>&1)"
docker logs "$name" >"$work/daemon.log" 2>&1
grep -Fx 'Exiting normally.' "$work/daemon.log" >/dev/null ||
  fail "no clean shutdown message: $(cat "$work/daemon.log")"
if grep -iE 'error|failed' "$work/daemon.log" >/dev/null; then
  fail "daemon logged errors: $(cat "$work/daemon.log")"
fi

# Default command: the packaged config (cpu, interface, load, memory into
# rrdtool, logging to syslog) as nonroot. It resolves its own FQDN, so the
# hostname is mapped to loopback instead of granting a network.
default="collectd-default-$$"
containers="$containers $default"
docker run -d --name "$default" --network none --hostname verity-default \
  --add-host verity-default:127.0.0.1 "$image" >/dev/null || fail 'default command did not start'
rrd="$work/rrd"
attempt=0
until [ -s "$rrd/load/load.rrd" ] && [ -s "$rrd/memory/memory-used.rrd" ]; do
  attempt=$((attempt + 1))
  if [ "$attempt" -gt 40 ]; then
    fail "default config wrote no RRDs within 40s: $(ls -R "$rrd" 2>&1)"
  fi
  test "$(docker inspect --format '{{.State.Running}}' "$default")" = true ||
    fail "default command exited early with $(docker inspect --format '{{.State.ExitCode}}' "$default")"
  sleep 1
  copy_out "$default" /var/lib/collectd/verity-default "$rrd" || true
done
test "$(dd if="$rrd/load/load.rrd" bs=3 count=1 2>/dev/null)" = RRD ||
  fail 'load.rrd is not an RRD file'
docker stop --time 10 "$default" >/dev/null || fail 'could not stop the default command'
test "$(docker inspect --format '{{.State.ExitCode}}' "$default")" = 0 ||
  fail 'default command exited non-zero on SIGTERM'

printf 'SMOKE PASS image=%s\n' "$image"
