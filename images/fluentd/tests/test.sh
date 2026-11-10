#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-fluentd-test-$$"
fixture=$(mktemp -d)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$fixture"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

user=$(docker image inspect --format '{{.Config.User}}' "$image")
test "$user" = 65532 || fail "unexpected image user: $user"

entrypoint=$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")
expected_entrypoint='["/usr/bin/tini","--","/usr/bin/entrypoint.sh"]'
test "$entrypoint" = "$expected_entrypoint" ||
  fail "unexpected image entrypoint: $entrypoint (want $expected_entrypoint)"

# Version reported by the binary.
version=$(docker run --rm --entrypoint fluentd "$image" --version)
printf '%s\n' "$version"
case "$version" in
  "fluentd 1.20."*) ;;
  *) fail "unexpected fluentd version: $version" ;;
esac

# Gem set of the upstream image (oj, rexml, async, async-http, yajl-ruby) loads
# with the extensions fluentd needs at runtime.
docker run --rm --entrypoint ruby "$image" -e '
  %w[oj yajl rexml/document async async/http msgpack cool.io http_parser strptime serverengine zstd-ruby].each { |lib| require lib }
  puts "gems load"
' | grep -Fx 'gems load' >/dev/null || fail "gem set failed to load"
gems=$(docker run --rm --entrypoint fluent-gem "$image" list --local)
for gem in fluentd oj rexml async async-http yajl-ruby; do
  printf '%s\n' "$gems" | grep -E "^$gem " >/dev/null || fail "gem not installed: $gem"
done

# The default configuration of the image is valid.
docker run --rm "$image" fluentd --dry-run >/dev/null 2>&1 || fail "default configuration failed --dry-run"

# in_http to out_file: POST an event and assert it lands in the output file.
mkdir "$fixture/out"
chmod 777 "$fixture/out"
cat > "$fixture/http.conf" <<'EOF'
<source>
  @type http
  bind 0.0.0.0
  port 9880
</source>

<match smoke.**>
  @type file
  path /out/events
  append true
  <buffer>
    @type memory
    flush_mode immediate
  </buffer>
</match>
EOF
chmod 644 "$fixture/http.conf"
chmod 755 "$fixture"

docker run --name "$container" -d \
  -v "$fixture/http.conf:/fluentd/etc/http.conf:ro" \
  -v "$fixture/out:/out" \
  -e FLUENTD_CONF=http.conf \
  -p 127.0.0.1::9880 "$image" >/dev/null
port=$(docker port "$container" 9880/tcp | awk -F: 'NR == 1 { print $NF }')
test -n "$port" || { docker logs "$container" >&2 || true; fail "no published port"; }

i=0
until status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --connect-timeout 1 --max-time 5 \
  -X POST -H 'Content-Type: application/json' \
  -d '{"msg":"verity-smoke-event"}' "http://127.0.0.1:$port/smoke.test") &&
  [ "$status" = 200 ]; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || { docker logs "$container" >&2; fail "in_http never accepted the event"; }
  sleep 1
done

i=0
until grep -rF 'verity-smoke-event' "$fixture/out" >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || { docker logs "$container" >&2; fail "event did not land in the output file"; }
  sleep 1
done
running=$(docker inspect --format '{{.State.Running}}' "$container")
test "$running" = true || { docker logs "$container" >&2 || true; fail "container stopped"; }

# Negative: an invalid configuration is rejected, both with --dry-run and at start.
cat > "$fixture/invalid.conf" <<'EOF'
<source>
  @type no_such_input_plugin
</source>
EOF
chmod 644 "$fixture/invalid.conf"

if docker run --rm -v "$fixture/invalid.conf:/fluentd/etc/invalid.conf:ro" \
  "$image" fluentd -c /fluentd/etc/invalid.conf --dry-run >/dev/null 2>&1; then
  fail "invalid config unexpectedly passed --dry-run"
fi
if docker run --rm -v "$fixture/invalid.conf:/fluentd/etc/invalid.conf:ro" \
  -e FLUENTD_CONF=invalid.conf "$image" >/dev/null 2>&1; then
  fail "invalid config unexpectedly started"
fi

printf 'SMOKE PASS image=%s\n' "$image"
