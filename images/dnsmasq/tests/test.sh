#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
config="$(dirname "$0")/../apko.yaml"
version=$(sed -n 's/^    - dnsmasq=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
# DNS client: the catalog coredns image ships Wolfi bind-tools (dig).
client_image='ghcr.io/tektum/coredns@sha256:efa6111f5e1daabd2c273812638c4ea6a3dbfc2466c76ec31d915e0d94541b1e'
server="verity-dnsmasq-server-$$"
upstream="verity-dnsmasq-upstream-$$"
forwarder="verity-dnsmasq-forwarder-$$"
defaults="verity-dnsmasq-defaults-$$"
rooted="verity-dnsmasq-rooted-$$"
work=$(mktemp -d)

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$server" "$upstream" "$forwarder" "$defaults" "$rooted" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail 'could not read the pinned dnsmasq version'

# OCI contract: non-root, foreground with logs on stderr, unprivileged port.
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/dnsmasq","--keep-in-foreground","--log-facility=-"]' ||
  fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = \
  '["--port=5353"]' || fail 'unexpected command'

docker run --rm --network none "$image" --version >"$work/version" 2>&1 ||
  fail "dnsmasq --version failed: $(cat "$work/version")"
grep -E "^Dnsmasq version $version " "$work/version" >/dev/null ||
  fail "dnsmasq --version does not report $version: $(cat "$work/version")"

# Fixtures, mounted read-only and readable by uid 65532.
mkdir "$work/conf" "$work/hosts"
cat >"$work/conf/dnsmasq.conf" <<'EOF'
port=5353
no-resolv
no-hosts
log-queries
address=/verity.test/10.1.2.3
local=/internal.test/
host-record=db.internal.test,10.1.2.4,fd00::4
addn-hosts=/etc/dnsmasq.hosts
EOF
printf '10.1.2.5 web.internal.test\n' >"$work/hosts/hosts"
printf 'port=5353\ndefinitely-not-an-option=yes\n' >"$work/conf/bad.conf"
chmod 755 "$work" "$work/conf" "$work/hosts"
chmod 644 "$work/conf/"* "$work/hosts/hosts"

# Negative cases: an unknown option and a broken config file exit non-zero
# with a diagnostic, and --test accepts the good config.
rc=0
docker run --rm --network none "$image" --definitely-not-an-option >"$work/bad-opt" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'dnsmasq accepted an unknown command-line option'
grep -F 'bad command line options' "$work/bad-opt" >/dev/null ||
  fail "unknown-option diagnostic is missing: $(cat "$work/bad-opt")"
rc=0
docker run --rm --network none -v "$work/conf:/conf:ro" "$image" \
  --conf-file=/conf/bad.conf >"$work/bad-conf" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'dnsmasq started with a broken config file'
grep -F 'bad option at line 2 of /conf/bad.conf' "$work/bad-conf" >/dev/null ||
  fail "broken-config diagnostic is missing: $(cat "$work/bad-conf")"
docker run --rm --network none -v "$work/conf:/conf:ro" "$image" \
  --conf-file=/conf/dnsmasq.conf --test >"$work/syntax" 2>&1 ||
  fail "dnsmasq --test rejected a valid config: $(cat "$work/syntax")"
grep -F 'syntax check OK' "$work/syntax" >/dev/null ||
  fail "dnsmasq --test did not report OK: $(cat "$work/syntax")"

# The client is a test tool, not the image under test: it runs on the daemon's
# native platform even when DOCKER_DEFAULT_PLATFORM selects an emulated server.
client_platform="linux/$(docker version --format '{{.Server.Arch}}')"
dig_in() {
  target=$1
  port=$2
  shift 2
  docker run --rm --platform "$client_platform" --network "container:$target" --cap-drop=ALL \
    --entrypoint dig "$client_image" -p "$port" @127.0.0.1 +time=2 +tries=1 "$@"
}

wait_ready() {
  target=$1
  port=$2
  name=$3
  want=$4
  i=0
  while [ "$i" -lt 60 ]; do
    if [ "$(docker inspect --format '{{.State.Running}}' "$target")" != true ]; then
      docker logs "$target" >&2 || true
      fail "$target exited before serving"
    fi
    if [ "$(dig_in "$target" "$port" "$name" A +short 2>/dev/null || true)" = "$want" ]; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  docker logs "$target" >&2 || true
  fail "$target did not answer $name with $want"
}

# Hardened run: read-only root, no capabilities, config from a read-only mount.
docker run -d --name "$server" --read-only --cap-drop=ALL \
  -v "$work/conf:/conf:ro" -v "$work/hosts/hosts:/etc/dnsmasq.hosts:ro" \
  "$image" --conf-file=/conf/dnsmasq.conf >/dev/null
wait_ready "$server" 5353 verity.test 10.1.2.3

docker top "$server" -o pid,uid,comm >"$work/top"
awk 'NR > 1 { rows++; if ($2 != 65532) bad = 1; if ($3 == "dnsmasq") found = 1 }
  END { exit !(rows && found && !bad) }' "$work/top" ||
  fail "dnsmasq is not running as uid 65532: $(cat "$work/top")"

# --address: the exact answer, also for subdomains, authoritative from config.
dig_in "$server" 5353 verity.test A >"$work/a"
grep -F 'status: NOERROR' "$work/a" >/dev/null || fail "verity.test did not return NOERROR: $(cat "$work/a")"
grep -E '^verity\.test\.[[:space:]]+[0-9]+[[:space:]]+IN[[:space:]]+A[[:space:]]+10\.1\.2\.3$' "$work/a" >/dev/null ||
  fail "verity.test answer is not exactly A 10.1.2.3: $(cat "$work/a")"
test "$(dig_in "$server" 5353 deep.sub.verity.test A +short)" = 10.1.2.3 ||
  fail '--address did not cover subdomains of verity.test'

# --host-record over UDP and TCP, A and AAAA, and the PTR it implies.
test "$(dig_in "$server" 5353 db.internal.test A +short)" = 10.1.2.4 ||
  fail 'host-record A did not return 10.1.2.4'
test "$(dig_in "$server" 5353 db.internal.test A +tcp +short)" = 10.1.2.4 ||
  fail 'host-record A over TCP did not return 10.1.2.4'
test "$(dig_in "$server" 5353 db.internal.test AAAA +short)" = fd00::4 ||
  fail 'host-record AAAA did not return fd00::4'
test "$(dig_in "$server" 5353 -x 10.1.2.4 +short)" = db.internal.test. ||
  fail 'host-record PTR did not return db.internal.test.'

# --addn-hosts from a read-only mount.
test "$(dig_in "$server" 5353 web.internal.test A +short)" = 10.1.2.5 ||
  fail 'addn-hosts did not return 10.1.2.5'

# Negative answers: NXDOMAIN inside the local-only domain, REFUSED for a name
# with no upstream (--no-resolv), and neither carries an answer.
dig_in "$server" 5353 missing.internal.test A >"$work/nx"
grep -F 'status: NXDOMAIN' "$work/nx" >/dev/null ||
  fail "unknown local name did not return NXDOMAIN: $(cat "$work/nx")"
grep -F ';; ANSWER SECTION:' "$work/nx" >/dev/null &&
  fail "NXDOMAIN response carries an answer: $(cat "$work/nx")"
dig_in "$server" 5353 unknown.example A >"$work/refused"
grep -F 'status: REFUSED' "$work/refused" >/dev/null ||
  fail "name without an upstream was not refused: $(cat "$work/refused")"
grep -F ';; ANSWER SECTION:' "$work/refused" >/dev/null &&
  fail "refused response carries an answer: $(cat "$work/refused")"

# Logs go to stderr (log-facility=-) and record the queries.
docker logs "$server" >"$work/server-log" 2>&1
grep -F "started, version $version" "$work/server-log" >/dev/null ||
  fail "server log lacks the startup line: $(cat "$work/server-log")"
grep -F 'config verity.test is 10.1.2.3' "$work/server-log" >/dev/null ||
  fail "server log lacks the verity.test query: $(cat "$work/server-log")"
grep -F 'config missing.internal.test is NXDOMAIN' "$work/server-log" >/dev/null ||
  fail "server log lacks the NXDOMAIN query: $(cat "$work/server-log")"

# SIGTERM stops the foreground process cleanly.
docker stop "$server" >/dev/null
test "$(docker inspect --format '{{.State.ExitCode}}' "$server")" = 0 ||
  fail 'dnsmasq did not exit 0 on SIGTERM'

# Forwarding and caching: an upstream instance on 5354 and a forwarder on 5353
# share one network namespace.
docker run -d --name "$upstream" --read-only --cap-drop=ALL "$image" \
  --port=5354 --no-resolv --no-hosts --log-queries \
  --local-ttl=300 --address=/upstream.test/10.9.8.7 >/dev/null
wait_ready "$upstream" 5354 upstream.test 10.9.8.7
docker run -d --name "$forwarder" --read-only --cap-drop=ALL --network "container:$upstream" \
  "$image" --port=5353 --no-resolv --no-hosts --log-queries --server=127.0.0.1#5354 >/dev/null
wait_ready "$forwarder" 5353 upstream.test 10.9.8.7
test "$(dig_in "$forwarder" 5353 upstream.test A +short)" = 10.9.8.7 ||
  fail 'forwarded query did not return 10.9.8.7'
docker logs "$forwarder" >"$work/forwarder-log" 2>&1
grep -F 'forwarded upstream.test to 127.0.0.1' "$work/forwarder-log" >/dev/null ||
  fail "forwarder did not forward upstream.test: $(cat "$work/forwarder-log")"
grep -F 'cached upstream.test is 10.9.8.7' "$work/forwarder-log" >/dev/null ||
  fail "forwarder did not answer the repeated query from cache: $(cat "$work/forwarder-log")"
docker stop "$forwarder" "$upstream" >/dev/null

# Default command: the image listens on 5353 as uid 65532 without arguments
# and answers from the image /etc/hosts.
docker run -d --name "$defaults" --cap-drop=ALL "$image" >/dev/null
wait_ready "$defaults" 5353 localhost 127.0.0.1
docker stop "$defaults" >/dev/null
test "$(docker inspect --format '{{.State.ExitCode}}' "$defaults")" = 0 ||
  fail 'default dnsmasq did not exit 0 on SIGTERM'

# Started as root (default capabilities), dnsmasq binds and then drops to its
# compiled default user nonroot (65532).
docker run -d --name "$rooted" --user 0 "$image" >/dev/null
wait_ready "$rooted" 5353 localhost 127.0.0.1
docker top "$rooted" -o pid,uid,comm >"$work/top-root"
awk 'NR > 1 { rows++; if ($2 != 65532) bad = 1; if ($3 == "dnsmasq") found = 1 }
  END { exit !(rows && found && !bad) }' "$work/top-root" ||
  fail "dnsmasq started as root did not drop to uid 65532: $(cat "$work/top-root")"
docker stop "$rooted" >/dev/null

printf 'SMOKE PASS image=%s\n' "$image"
