#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
config="$(dirname "$0")/../apko.yaml"
version=$(sed -n 's/^    - nsd=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
# DNS client: the catalog coredns image ships Wolfi bind-tools (dig).
client_image='ghcr.io/tektum/coredns@sha256:efa6111f5e1daabd2c273812638c4ea6a3dbfc2466c76ec31d915e0d94541b1e'
server="verity-nsd-server-$$"
hardened="verity-nsd-hardened-$$"
work=$(mktemp -d)

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$server" "$hardened" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail 'could not read the pinned nsd version'

# OCI contract.
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/nsd"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = \
  '["-d","-c","/etc/nsd/nsd.conf"]' || fail 'unexpected command'

docker run --rm --network none "$image" -v >"$work/version" 2>&1 ||
  fail 'nsd -v failed'
grep -Fx "NSD version $version" "$work/version" >/dev/null ||
  fail "nsd -v does not report NSD version $version"

# Fixtures: a zone served from a read-only mount on an unprivileged port, with
# NSD told not to switch to its default 'nsd' user.
mkdir "$work/zones"
cat >"$work/nsd.conf" <<'EOF'
server:
  ip-address: 127.0.0.1
  port: 5353
  server-count: 1
  username: ""
  pidfile: ""
  zonesdir: /etc/nsd/zones
  verbosity: 1

zone:
  name: example.test
  zonefile: example.test.zone
EOF
cat >"$work/zones/example.test.zone" <<'EOF'
$ORIGIN example.test.
$TTL 300
@    IN SOA ns1.example.test. hostmaster.example.test. 2026111601 3600 900 604800 300
@    IN NS  ns1.example.test.
ns1  IN A   192.0.2.53
www  IN A   192.0.2.80
EOF
# Broken configuration: an unknown server option.
cat >"$work/bad.conf" <<'EOF'
server:
  port: 5353
  definitely-not-an-option: yes
EOF
# Broken zones: an invalid A address, and a zone without an SOA record.
cat >"$work/zones/bad-address.zone" <<'EOF'
$ORIGIN example.test.
$TTL 300
@    IN SOA ns1.example.test. hostmaster.example.test. 1 3600 900 604800 300
@    IN NS  ns1.example.test.
www  IN A   999.0.2.80
EOF
cat >"$work/zones/no-soa.zone" <<'EOF'
$ORIGIN example.test.
$TTL 300
www  IN A   192.0.2.80
EOF
# The server runs as 65532, so the mounted inputs must be world-readable.
chmod 755 "$work" "$work/zones"
chmod 644 "$work/nsd.conf" "$work/bad.conf" "$work/zones/"*

tool() {
  name=$1
  shift
  docker run --rm --network none --entrypoint "/usr/bin/$name" \
    -v "$work:/work:ro" "$image" "$@"
}

# nsd-checkconf accepts the good configuration and rejects the broken one.
tool nsd-checkconf /work/nsd.conf >"$work/checkconf-ok" 2>&1 ||
  fail "nsd-checkconf rejected a valid configuration: $(cat "$work/checkconf-ok")"
test "$(tool nsd-checkconf -o port /work/nsd.conf)" = 5353 ||
  fail 'nsd-checkconf -o port did not read the configured port'
rc=0
tool nsd-checkconf /work/bad.conf >"$work/checkconf-bad" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'nsd-checkconf accepted a broken configuration'
grep -F 'definitely-not-an-option' "$work/checkconf-bad" >/dev/null ||
  fail "nsd-checkconf diagnostic does not name the bad option: $(cat "$work/checkconf-bad")"

# nsd-checkzone accepts the good zone and rejects both broken zones.
tool nsd-checkzone example.test /work/zones/example.test.zone >"$work/checkzone-ok" 2>&1 ||
  fail "nsd-checkzone rejected a valid zone: $(cat "$work/checkzone-ok")"
grep -Fx 'zone example.test is ok' "$work/checkzone-ok" >/dev/null ||
  fail "nsd-checkzone did not report the zone ok: $(cat "$work/checkzone-ok")"
rc=0
tool nsd-checkzone example.test /work/zones/bad-address.zone >"$work/checkzone-bad" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'nsd-checkzone accepted an invalid A address'
grep -F 'Invalid address in A' "$work/checkzone-bad" >/dev/null ||
  fail "nsd-checkzone diagnostic is missing: $(cat "$work/checkzone-bad")"
rc=0
tool nsd-checkzone example.test /work/zones/no-soa.zone >"$work/checkzone-nosoa" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'nsd-checkzone accepted a zone without an SOA record'
grep -F 'has no SOA record' "$work/checkzone-nosoa" >/dev/null ||
  fail "nsd-checkzone SOA diagnostic is missing: $(cat "$work/checkzone-nosoa")"

# The daemon itself refuses a missing or broken configuration.
rc=0
docker run --rm --network none "$image" >"$work/missing" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'nsd started without a configuration'
rc=0
docker run --rm --network none -v "$work/bad.conf:/etc/nsd/nsd.conf:ro" "$image" \
  >"$work/bad-start" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'nsd started with a broken configuration'
grep -F 'definitely-not-an-option' "$work/bad-start" >/dev/null ||
  fail "nsd broken-configuration diagnostic is missing: $(cat "$work/bad-start")"

dig_in() {
  target=$1
  shift
  docker run --rm --network "container:$target" --cap-drop=ALL \
    --entrypoint dig "$client_image" -p 5353 @127.0.0.1 +norec +time=2 +tries=1 "$@"
}

wait_ready() {
  target=$1
  i=0
  while [ "$i" -lt 30 ]; do
    if [ "$(docker inspect --format '{{.State.Running}}' "$target")" != true ]; then
      docker logs "$target" >&2 || true
      fail "$target exited before serving"
    fi
    if dig_in "$target" example.test SOA +short 2>/dev/null |
      grep -F '2026111601' >/dev/null; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  docker logs "$target" >&2 || true
  fail "$target did not answer the SOA query"
}

# Default command, writable image root: zone and config are read-only mounts.
docker run -d --name "$server" --cap-drop=ALL \
  -v "$work/nsd.conf:/etc/nsd/nsd.conf:ro" \
  -v "$work/zones:/etc/nsd/zones:ro" "$image" >/dev/null
wait_ready "$server"

docker top "$server" -o pid,uid,comm >"$work/top"
awk 'NR > 1 { rows++; if ($2 != 65532) bad = 1; if ($3 ~ /^nsd/) found = 1 }
  END { exit !(rows && found && !bad) }' "$work/top" ||
  fail "nsd processes are not running as uid 65532: $(cat "$work/top")"

# A record: authoritative answer.
dig_in "$server" www.example.test A >"$work/a"
grep -F 'status: NOERROR' "$work/a" >/dev/null || fail "A query did not return NOERROR: $(cat "$work/a")"
grep -E '^;; flags:.* aa[ ;]' "$work/a" >/dev/null || fail "A answer is not authoritative: $(cat "$work/a")"
test "$(dig_in "$server" www.example.test A +short)" = 192.0.2.80 ||
  fail 'A query did not return 192.0.2.80'

# SOA record.
test "$(dig_in "$server" example.test SOA +short)" = \
  'ns1.example.test. hostmaster.example.test. 2026111601 3600 900 604800 300' ||
  fail 'SOA query returned unexpected data'

# The same zone over TCP.
test "$(dig_in "$server" ns1.example.test A +tcp +short)" = 192.0.2.53 ||
  fail 'TCP A query did not return 192.0.2.53'

# NXDOMAIN inside the zone, with the SOA in the authority section.
dig_in "$server" missing.example.test A >"$work/nx"
grep -F 'status: NXDOMAIN' "$work/nx" >/dev/null || fail "missing name did not return NXDOMAIN: $(cat "$work/nx")"
grep -E '^;; flags:.* aa[ ;]' "$work/nx" >/dev/null || fail "NXDOMAIN is not authoritative: $(cat "$work/nx")"
grep -E '^example\.test\.[[:space:]]+[0-9]+[[:space:]]+IN[[:space:]]+SOA[[:space:]]' "$work/nx" >/dev/null ||
  fail "NXDOMAIN response lacks the zone SOA: $(cat "$work/nx")"

# Out-of-zone query: NSD is authoritative only and must refuse it.
dig_in "$server" www.example.org A >"$work/refused"
grep -F 'status: REFUSED' "$work/refused" >/dev/null ||
  fail "out-of-zone query was not refused: $(cat "$work/refused")"
grep -E '^;; ANSWER SECTION:' "$work/refused" >/dev/null &&
  fail "out-of-zone query returned an answer: $(cat "$work/refused")"

docker logs "$server" >"$work/server-log" 2>&1
grep -F 'zone example.test read with success' "$work/server-log" >/dev/null ||
  fail "server log does not report the zone load: $(cat "$work/server-log")"

# SIGTERM stops cleanly and the xfr daemon writes its exit state to the
# image-owned /var/db/nsd.
docker stop "$server" >/dev/null
test "$(docker inspect --format '{{.State.ExitCode}}' "$server")" = 0 ||
  fail 'nsd did not exit 0 on SIGTERM'
docker cp "$server:/var/db/nsd/xfrd.state" "$work/xfrd.state" >/dev/null 2>&1 ||
  fail 'nsd did not write /var/db/nsd/xfrd.state'
test "$(sed -n 1p "$work/xfrd.state")" = NSDXFRD2 ||
  fail "xfrd.state lacks the NSDXFRD2 header: $(cat "$work/xfrd.state")"

# Hardened run: read-only root with tmpfs for NSD's state and transfer dirs.
docker run -d --name "$hardened" --read-only --cap-drop=ALL \
  --tmpfs /tmp:rw,mode=1777 \
  --tmpfs /var/db/nsd:rw,uid=65532,gid=65532,mode=0755 \
  -v "$work/nsd.conf:/etc/nsd/nsd.conf:ro" \
  -v "$work/zones:/etc/nsd/zones:ro" "$image" >/dev/null
wait_ready "$hardened"
test "$(dig_in "$hardened" www.example.test A +short)" = 192.0.2.80 ||
  fail 'read-only server did not return 192.0.2.80'
docker stop "$hardened" >/dev/null
test "$(docker inspect --format '{{.State.ExitCode}}' "$hardened")" = 0 ||
  fail 'read-only nsd did not exit 0 on SIGTERM'

printf 'SMOKE PASS image=%s\n' "$image"
