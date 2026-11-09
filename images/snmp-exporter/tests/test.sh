#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
exporter="verity-snmp-exporter-$$"
tmp=$(mktemp -d)

cleanup() {
  docker rm -f "$exporter" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

version=$(awk -F'"' '$1 ~ /^  version:/ { print $2; exit }' "$here/../melange.yaml")
test -n "$version" || fail 'cannot read the package version from melange.yaml'

test "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532 ||
  fail 'image must run as UID 65532'
test "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/snmp_exporter"]' ||
  fail 'unexpected entrypoint'
test "$(docker image inspect "$image" --format '{{json .Config.Cmd}}')" = '["--config.file=/etc/snmp_exporter/snmp.yml"]' ||
  fail 'unexpected default command'

docker run --rm "$image" --version >"$tmp/version" 2>&1 ||
  fail 'snmp_exporter --version failed'
grep -F "snmp_exporter, version $version " "$tmp/version" >/dev/null ||
  { cat "$tmp/version" >&2; fail "version output does not report $version"; }
revision=$(sed -n 's/.*revision: \([0-9a-f]\{40\}\)).*/\1/p' "$tmp/version")
test -n "$revision" || fail 'version output does not carry the source revision'

# The shipped default snmp.yml must parse with the default command.
docker run --rm "$image" --config.file=/etc/snmp_exporter/snmp.yml --dry-run >"$tmp/dryrun.log" 2>&1 ||
  { cat "$tmp/dryrun.log" >&2; fail 'default snmp.yml does not parse'; }
grep -F 'Configuration parsed successfully' "$tmp/dryrun.log" >/dev/null ||
  fail 'dry run did not confirm the configuration'

# An invalid config must stop the exporter with a readable error.
printf '%s\n' 'modules: [this is not valid' >"$tmp/invalid.yml"
chmod 644 "$tmp/invalid.yml"
if docker run --rm -v "$tmp/invalid.yml:/tmp/invalid.yml:ro" "$image" \
  --config.file=/tmp/invalid.yml >"$tmp/invalid.log" 2>&1; then
  fail 'invalid config unexpectedly succeeded'
fi
grep -F 'Error parsing config file' "$tmp/invalid.log" >/dev/null ||
  { cat "$tmp/invalid.log" >&2; fail 'invalid config error is not readable'; }

# An unknown flag must be rejected, not ignored.
if docker run --rm "$image" --verity.no-such-flag >"$tmp/flag.log" 2>&1; then
  fail 'unknown flag unexpectedly succeeded'
fi
grep -F 'unknown long flag' "$tmp/flag.log" >/dev/null ||
  { cat "$tmp/flag.log" >&2; fail 'unknown flag error is not readable'; }

docker run --name "$exporter" -d --read-only -p 127.0.0.1::9116 "$image" >/dev/null
web_port=$(docker port "$exporter" 9116/tcp | awk -F: 'NR == 1 { print $2 }')
test -n "$web_port" || fail 'exporter port 9116 is not published'

attempts=0
until curl --fail --silent --connect-timeout 1 --max-time 5 \
  "http://127.0.0.1:$web_port/" >"$tmp/landing" 2>/dev/null; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || { docker logs "$exporter" >&2; fail 'exporter did not become ready'; }
  sleep 1
done
grep -F '<title>SNMP Exporter</title>' "$tmp/landing" >/dev/null ||
  fail 'landing page is not the SNMP Exporter HTML page'

curl --fail --silent --max-time 5 "http://127.0.0.1:$web_port/config" >"$tmp/config" ||
  fail '/config request failed'
grep -F 'if_mib:' "$tmp/config" >/dev/null || fail 'default snmp.yml is missing the if_mib module'

# Nothing answers SNMP on loopback in the container: the scrape must report the
# error in the response, and the exporter must keep running.
status=$(curl --silent --max-time 30 -o "$tmp/scrape" -w '%{http_code}' \
  "http://127.0.0.1:$web_port/snmp?target=127.0.0.1&module=if_mib") ||
  fail 'scrape request failed'
[ "$status" = 500 ] || { cat "$tmp/scrape" >&2; fail "scrape of an unreachable target returned HTTP $status"; }
grep -F 'snmp_error' "$tmp/scrape" >/dev/null || fail 'scrape error did not name snmp_error'
grep -F 'error walking target 127.0.0.1' "$tmp/scrape" >/dev/null ||
  { cat "$tmp/scrape" >&2; fail 'scrape error is not readable'; }
[ "$(docker inspect --format '{{.State.Running}}' "$exporter")" = true ] ||
  { docker logs "$exporter" >&2; fail 'exporter crashed on a failed scrape'; }

status=$(curl --silent --max-time 10 -o /dev/null -w '%{http_code}' \
  "http://127.0.0.1:$web_port/snmp?target=127.0.0.1&module=verity_no_such_module") ||
  fail 'unknown module request failed'
[ "$status" = 400 ] || fail "unknown module returned HTTP $status"

curl --fail --silent --max-time 5 "http://127.0.0.1:$web_port/metrics" >"$tmp/metrics" ||
  fail '/metrics request failed'
grep -F 'snmp_exporter_build_info{' "$tmp/metrics" | grep -F "revision=\"$revision\"" |
  grep -F "version=\"$version\"" >/dev/null ||
  fail 'snmp_exporter_build_info does not match --version'

# The exporter does not trap SIGTERM, so as PID 1 it exits 2 (Go) or 143; it
# must stop at once and not be killed after the grace period (137).
docker stop --time 10 "$exporter" >/dev/null
case $(docker inspect --format '{{.State.ExitCode}}' "$exporter") in
  0 | 2 | 143) ;;
  *) fail 'exporter did not stop on SIGTERM' ;;
esac

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$version"
