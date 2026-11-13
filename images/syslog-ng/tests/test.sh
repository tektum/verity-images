#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
container="syslog-ng-smoke-$$"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  docker logs "$container" >&2 2>&1 || true
  exit 1
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
expected_entrypoint='["/usr/bin/syslog-ng","--foreground","--no-caps","--cfgfile=/etc/syslog-ng/syslog-ng.conf",'
expected_entrypoint="${expected_entrypoint}\"--persist-file=/var/lib/syslog-ng/syslog-ng.persist\","
expected_entrypoint="${expected_entrypoint}\"--pidfile=/var/lib/syslog-ng/syslog-ng.pid\","
expected_entrypoint="${expected_entrypoint}\"--control=/var/lib/syslog-ng/syslog-ng.ctl\"]"
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = "$expected_entrypoint" ||
  fail 'unexpected entrypoint'

docker run --rm --network none "$image" --version >"$work/version" || fail 'syslog-ng --version failed'
grep -E '^Installer-Version: 4\.12\.[0-9]+$' "$work/version" >/dev/null || fail 'unexpected syslog-ng version'
for module in afsocket affile json-plugin; do
  grep -E "^Available-Modules: .*\b$module\b" "$work/version" >/dev/null || fail "module $module is missing"
done

cat >"$work/syslog-ng.conf" <<'EOF'
@version: 4.12
options { stats(freq(0)); };
source s_net { network(transport("tcp") port(5514) flags(no-parse)); };
destination d_file { file("/var/log/syslog-ng/messages" template("received $MSG\n") perm(0644)); };
log { source(s_net); destination(d_file); };
EOF
chmod 0644 "$work/syslog-ng.conf"
mkdir -m 0777 "$work/log"

docker run --rm --network none -v "$work/syslog-ng.conf:/etc/syslog-ng/syslog-ng.conf:ro" "$image" --syntax-only ||
  fail 'valid configuration did not pass --syntax-only'

# Negative: a broken configuration must be rejected by --syntax-only.
printf '@version: 4.12\nsource s_bad { no_such_driver(); };\n' >"$work/broken.conf"
chmod 0644 "$work/broken.conf"
if docker run --rm --network none -v "$work/broken.conf:/etc/syslog-ng/syslog-ng.conf:ro" "$image" \
  --syntax-only >"$work/broken.log" 2>&1; then
  fail 'broken configuration unexpectedly passed --syntax-only'
fi
grep -F 'Error parsing config' "$work/broken.log" >/dev/null || fail 'broken configuration error was not reported'

# Negative: the image ships no configuration at the documented path, so a bare start must fail.
# Bound the run: a regression that ships a usable default would otherwise serve forever.
bare_status=0
timeout 30 docker run --rm --name "$container" --network none "$image" >"$work/bare.log" 2>&1 || bare_status=$?
docker rm -f "$container" >/dev/null 2>&1 || true
case "$bare_status" in
  0) fail 'syslog-ng started without a mounted configuration' ;;
  124) fail 'syslog-ng started without a mounted configuration (still running after 30s)' ;;
esac
grep -F "Error opening configuration file; filename='/etc/syslog-ng/syslog-ng.conf'" "$work/bare.log" >/dev/null ||
  fail 'bare start did not fail on the missing configuration file'

docker run -d --name "$container" --read-only \
  -v "$work/syslog-ng.conf:/etc/syslog-ng/syslog-ng.conf:ro" \
  -v "$work/log:/var/log/syslog-ng" \
  --tmpfs /var/lib/syslog-ng:uid=65532,gid=65532 "$image" >/dev/null

attempt=0
until docker exec "$container" /usr/bin/syslog-ng-ctl healthcheck \
  --control=/var/lib/syslog-ng/syslog-ng.ctl >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 30 ] || fail 'syslog-ng did not become healthy'
  sleep 1
done

# Send messages over TCP with the bundled loggen client.
docker run --rm --network "container:$container" --entrypoint /usr/bin/loggen "$image" \
  --inet --stream --number=3 --dont-parse --size=128 127.0.0.1 5514 >"$work/loggen.log" 2>&1 ||
  fail 'loggen could not send messages'

attempt=0
until [ -f "$work/log/messages" ] && [ "$(grep -c '^received ' "$work/log/messages")" -ge 3 ]; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 30 ] || fail 'messages were not written to the file destination'
  sleep 1
done

docker exec "$container" /usr/bin/syslog-ng-ctl stats --control=/var/lib/syslog-ng/syslog-ng.ctl >"$work/stats" ||
  fail 'syslog-ng-ctl stats failed'
grep -E 'd_file.*;processed;[1-9]' "$work/stats" >/dev/null || fail 'stats do not show processed messages'

docker stop --time 15 "$container" >/dev/null
test "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 || fail 'graceful shutdown did not exit 0'

printf 'SMOKE PASS image=%s\n' "$image"
