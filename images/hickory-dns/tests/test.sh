#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
recipe="$(dirname "$0")/../melange.yaml"
version=$(sed -n 's/^  version: "\([0-9.]*\)".*$/\1/p' "$recipe")
label="verity-test=hickory-dns-$$"
work=$(mktemp -d)
container=verity-hickory-dns-smoke-$$

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

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/hickory-dns"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /var/named ||
  fail 'unexpected working directory'

run() {
  docker run --rm --label "$label" --network none --read-only --cap-drop ALL \
    --security-opt no-new-privileges -v "$work/zones:/var/named:ro" "$image" "$@"
}

mkdir -p "$work/zones"
cat >"$work/zones/named.toml" <<'TOML'
listen_addrs_ipv4 = ["0.0.0.0"]

[[zones]]
zone = "verity.test"
zone_type = "Primary"
file = "verity.test.zone"
TOML
cat >"$work/zones/verity.test.zone" <<'ZONE'
$ORIGIN verity.test.
$TTL 300
@       IN SOA ns1.verity.test. hostmaster.verity.test. (
            2026111301 3600 600 86400 300 )
        IN NS  ns1.verity.test.
ns1     IN A   192.0.2.53
www     IN A   192.0.2.10
www     IN A   192.0.2.11
api     IN CNAME www.verity.test.
txt     IN TXT "verity smoke"
ZONE
# A zone file with a record outside any valid syntax.
cat >"$work/zones/invalid.toml" <<'TOML'
[[zones]]
zone = "broken.test"
zone_type = "Primary"
file = "broken.test.zone"
TOML
cat >"$work/zones/broken.test.zone" <<'ZONE'
$ORIGIN broken.test.
@ IN SOA ns1 hostmaster 1 3600 600 86400 300
www IN A not-an-address
ZONE
chmod -R a+rX "$work/zones"

# stdout only: docker prints a platform mismatch warning on stderr for emulated arm64 runs.
out=$(run --version) || fail 'version failed'
test "$out" = "Hickory DNS named server $version" ||
  fail "version does not report $version: $out"

# Negative: an unknown flag is rejected.
if run --definitely-not-a-flag >"$work/bad.log" 2>&1; then
  fail 'unknown flag was accepted'
fi
grep -q "unexpected argument '--definitely-not-a-flag'" "$work/bad.log" ||
  fail "unexpected unknown-flag error: $(cat "$work/bad.log")"

run --validate --config /var/named/named.toml --zonedir /var/named >"$work/valid.log" 2>&1 ||
  fail "valid configuration rejected: $(cat "$work/valid.log")"

# Negative: an invalid zone fails validation and startup.
if run --validate --config /var/named/invalid.toml --zonedir /var/named >"$work/invalid.log" 2>&1; then
  fail 'invalid zone passed validation'
fi
grep -qi 'not-an-address\|failed to load\|error' "$work/invalid.log" ||
  fail "unexpected invalid-zone error: $(cat "$work/invalid.log")"
if run --config /var/named/invalid.toml --zonedir /var/named --port 5353 >"$work/invalid-start.log" 2>&1; then
  fail 'server started with an invalid zone'
fi

# Negative: a missing default configuration is reported.
if run >"$work/noconfig.log" 2>&1; then
  fail 'started without a configuration'
fi
grep -q '/etc/named.toml' "$work/noconfig.log" ||
  fail "unexpected missing-config error: $(cat "$work/noconfig.log")"

docker run -d --name "$container" --label "$label" --read-only --cap-drop ALL \
  --security-opt no-new-privileges -v "$work/zones:/var/named:ro" \
  -p 127.0.0.1::5353/udp -p 127.0.0.1::5353/tcp -p 127.0.0.1::9000/tcp "$image" \
  --config /var/named/named.toml --zonedir /var/named --port 5353 \
  --prometheus-listen-address 0.0.0.0:9000 >/dev/null

port_of() {
  docker port "$container" "$1" | sed -n 's/^127\.0\.0\.1:\([0-9]*\)$/\1/p' | sed -n 1p
}
udp_port=$(port_of 5353/udp)
tcp_port=$(port_of 5353/tcp)
metrics_port=$(port_of 9000/tcp)
[ -n "$udp_port" ] && [ -n "$tcp_port" ] && [ -n "$metrics_port" ] || fail 'ports were not published'

# Minimal DNS client (RFC 1035 wire format) over UDP and TCP.
cat >"$work/dnsq.py" <<'PY'
import random
import socket
import struct
import sys

proto, port, name, qtype = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
types = {"A": 1, "NS": 2, "CNAME": 5, "SOA": 6, "TXT": 16}
qid = random.randint(0, 65535)
question = b"".join(bytes([len(p)]) + p.encode() for p in name.rstrip(".").split(".")) + b"\0"
query = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0) + question + struct.pack(">HH", types[qtype], 1)

if proto == "udp":
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(2)
    s.sendto(query, ("127.0.0.1", port))
    msg = s.recv(4096)
else:
    s = socket.create_connection(("127.0.0.1", port), timeout=2)
    s.sendall(struct.pack(">H", len(query)) + query)
    data = b""
    while len(data) < 2 or len(data) < 2 + struct.unpack(">H", data[:2])[0]:
        chunk = s.recv(4096)
        if not chunk:
            break
        data += chunk
    msg = data[2:]

rid, flags, qd, an, ns, ar = struct.unpack(">HHHHHH", msg[:12])
assert rid == qid, "id mismatch"


def read_name(off):
    labels = []
    jumped = False
    end = off
    while True:
        n = msg[off]
        if n & 0xC0 == 0xC0:
            if not jumped:
                end = off + 2
            off = ((n & 0x3F) << 8) | msg[off + 1]
            jumped = True
            continue
        if n == 0:
            if not jumped:
                end = off + 1
            break
        labels.append(msg[off + 1:off + 1 + n].decode())
        off += 1 + n
    return ".".join(labels) + ".", end


off = 12
for _ in range(qd):
    _, off = read_name(off)
    off += 4
print("rcode=%d aa=%d" % (flags & 0xF, (flags >> 10) & 1))
for _ in range(an):
    rname, off = read_name(off)
    rtype, _, _, rdlen = struct.unpack(">HHIH", msg[off:off + 10])
    off += 10
    rdata = msg[off:off + rdlen]
    if rtype == 1:
        value = socket.inet_ntoa(rdata)
    elif rtype in (2, 5):
        value = read_name(off)[0]
    elif rtype == 16:
        value = rdata[1:1 + rdata[0]].decode()
    else:
        value = rdata.hex()
    print("%s %d %s" % (rname, rtype, value))
    off += rdlen
PY

query() {
  python3 "$work/dnsq.py" "$@"
}

attempts=0
until query udp "$udp_port" ns1.verity.test A >"$work/ready" 2>/dev/null; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || {
    docker logs "$container" >&2 || true
    fail 'server did not answer'
  }
  sleep 1
done

for proto in udp tcp; do
  port=$udp_port
  [ "$proto" = udp ] || port=$tcp_port
  query "$proto" "$port" www.verity.test A >"$work/www.$proto" ||
    fail "$proto A query failed"
  grep -qx 'rcode=0 aa=1' "$work/www.$proto" || fail "$proto A not authoritative: $(cat "$work/www.$proto")"
  grep -qx 'www.verity.test. 1 192.0.2.10' "$work/www.$proto" || fail "$proto A missing .10"
  grep -qx 'www.verity.test. 1 192.0.2.11' "$work/www.$proto" || fail "$proto A missing .11"
done

query udp "$udp_port" api.verity.test A >"$work/cname" || fail 'CNAME query failed'
grep -qx 'api.verity.test. 5 www.verity.test.' "$work/cname" || fail "CNAME missing: $(cat "$work/cname")"
grep -qx 'www.verity.test. 1 192.0.2.10' "$work/cname" || fail "CNAME target not chased: $(cat "$work/cname")"
query tcp "$tcp_port" txt.verity.test TXT >"$work/txt" || fail 'TXT query failed'
grep -qx 'txt.verity.test. 16 verity smoke' "$work/txt" || fail "TXT missing: $(cat "$work/txt")"

# Negative: a name absent from the zone is NXDOMAIN; a foreign zone is refused.
query udp "$udp_port" missing.verity.test A >"$work/nx" || fail 'NXDOMAIN query failed'
grep -qx 'rcode=3 aa=1' "$work/nx" || fail "missing name not NXDOMAIN: $(cat "$work/nx")"
query udp "$udp_port" example.com A >"$work/refused" || fail 'foreign query failed'
grep -qx 'rcode=5 aa=0' "$work/refused" || fail "foreign zone not refused: $(cat "$work/refused")"

python3 -c 'import sys, urllib.request; sys.stdout.write(urllib.request.urlopen(sys.argv[1], timeout=5).read().decode())' \
  "http://127.0.0.1:$metrics_port/metrics" >"$work/metrics" || fail 'metrics endpoint failed'
grep -q '^hickory_' "$work/metrics" || fail 'metrics endpoint has no hickory metrics'

printf 'SMOKE PASS image=%s\n' "$image"
