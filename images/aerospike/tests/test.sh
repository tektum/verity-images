#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
version=$(sed -n 's/^  version: "\([0-9.]*\)".*/\1/p' "$here/../melange.yaml")
# Catalog Python 3.13, pinned by index digest, speaks the Aerospike wire
# protocol from inside the server's network namespace.
python_index=ghcr.io/tektum/python@sha256:d059268a2e4f0ef0cc82bb50c847e69e16e174736758013a153cb36311fa6dd6
label="verity-test=aerospike-$$"
memory="verity-aerospike-mem-$$"
disk="verity-aerospike-disk-$$"
probe="verity-aerospike-probe-$$"
invalid="verity-aerospike-invalid-$$"
volume="verity-aerospike-data-$$"
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  docker rm -f "$memory" "$disk" "$probe" "$invalid" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail 'could not read package.version from melange.yaml'

# Image contract: non-root, asd in the foreground, upstream paths.
[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] ||
  fail 'image does not run as UID 65532'
entrypoint=$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")
[ "$entrypoint" = '["/usr/bin/asd","--fgdaemon"]' ] ||
  fail "unexpected entrypoint: $entrypoint"
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /opt/aerospike ] ||
  fail 'working directory is not /opt/aerospike'

out=$(docker run --rm --label "$label" --network none "$image" --version) ||
  fail 'asd --version failed'
printf '%s\n' "$out"
[ "$out" = "Aerospike Community Edition build $version" ] ||
  fail "unexpected asd --version output: $out"

image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
# pull_child INDEX: pull the pinned index by its per-platform child digest,
# verifying the index bytes against the pin first so the pin stays authoritative.
pull_child() {
  raw=$(docker buildx imagetools inspect --raw "$1") || fail "cannot inspect $1"
  [ "sha256:$(printf '%s' "$raw" | sha256sum | cut -d' ' -f1)" = "${1#*@}" ] ||
    fail "index digest mismatch for $1"
  child=$(printf '%s' "$raw" | jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') || fail "cannot resolve a child of $1"
  case $child in
    sha256:*) ;;
    *) fail "no unique linux/$image_arch child in $1" ;;
  esac
  docker pull --quiet --platform "linux/$image_arch" "${1%%@*}@$child" >/dev/null ||
    fail "cannot pull ${1%%@*}@$child"
  printf '%s' "${1%%@*}@$child"
}
python_image=$(pull_child "$python_index")

# Layout from the exported root filesystem; the image ships no shell.
docker create --name "$probe" --label "$label" "$image" >/dev/null || fail 'could not create a layout probe'
layout=$(docker export "$probe" | docker run --rm -i --label "$label" --network none \
  --entrypoint python3 "$python_image" -c '
import sys, tarfile
t = {m.name.lstrip("./").rstrip("/"): m for m in tarfile.open(fileobj=sys.stdin.buffer, mode="r|")}
for p in ("etc/aerospike/aerospike.conf", "opt/aerospike/schema/aerospike_config_schema.json",
          "opt/aerospike/doc/LICENSE-AGPL", "licenses/LICENSE", "usr/bin/asd"):
    if p not in t or not (t[p].isfile() or t[p].issym()):
        print("missing /" + p)
for d in ("opt/aerospike", "opt/aerospike/data", "opt/aerospike/smd", "opt/aerospike/usr/udf/lua"):
    if d not in t or not t[d].isdir() or (t[d].uid, t[d].gid) != (65532, 65532):
        print("not a 65532-owned directory: /" + d)
for p in t:
    if p.startswith("etc/aerospike/features") or "enterprise" in p.lower():
        print("unexpected Enterprise artifact: /" + p)
') || fail 'layout probe failed'
docker rm "$probe" >/dev/null
[ -z "$layout" ] || fail "image layout: $layout"

mkdir -p "$work/fixture"
# Minimal client for the info protocol (proto type 1) and single-record
# AS_MSG reads and writes (proto type 3) addressed by digest.
cat >"$work/fixture/as.py" <<'PY'
import socket
import struct
import sys


def recv(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise SystemExit("connection closed after %d of %d bytes" % (len(buf), n))
        buf += chunk
    return buf


def call(port, ptype, body):
    with socket.create_connection(("127.0.0.1", port), 2) as sock:
        sock.settimeout(5)
        sock.sendall(struct.pack(">Q", (2 << 56) | (ptype << 48) | len(body)) + body)
        (word,) = struct.unpack(">Q", recv(sock, 8))
        if word >> 56 != 2 or (word >> 48) & 0xFF != ptype:
            raise SystemExit("unexpected proto header %016x" % word)
        return recv(sock, word & 0xFFFFFFFFFFFF)


def field(ftype, data):
    return struct.pack(">IB", len(data) + 1, ftype) + data


def op(code, ptype, name, value=b""):
    return struct.pack(">IBBBB", 4 + len(name) + len(value), code, ptype, 0, len(name)) + name + value


def as_msg(info1, info2, ns, digest, ops):
    fields = field(0, ns.encode()) + field(4, bytes.fromhex(digest))
    header = struct.pack(">BBBBBBIIIHH", 22, info1, info2, 0, 0, 0, 0, 0, 1000, 2, len(ops))
    return header + fields + b"".join(ops)


def reply(body):
    result, n_fields, n_ops = body[5], *struct.unpack(">HH", body[18:22])
    pos = body[0]
    for _ in range(n_fields):
        pos += 4 + struct.unpack(">I", body[pos:pos + 4])[0]
    bins = {}
    for _ in range(n_ops):
        size, _, ptype, _, name_sz = struct.unpack(">IBBBB", body[pos:pos + 8])
        name = body[pos + 8:pos + 8 + name_sz].decode()
        bins[name] = (ptype, body[pos + 8 + name_sz:pos + 4 + size])
        pos += 4 + size
    return result, bins


cmd, port, args = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
if cmd == "info":
    sys.stdout.write(call(port, 1, "".join(a + "\n" for a in args).encode()).decode())
elif cmd == "connect":
    socket.create_connection(("127.0.0.1", port), 2).close()
elif cmd == "put":
    ns, digest, name, value = args
    body = as_msg(0, 1, ns, digest, [op(2, 3, name.encode(), value.encode())])
    result, _ = reply(call(port, 3, body))
    print("result=%d" % result)
elif cmd == "get":
    ns, digest, name = args
    result, bins = reply(call(port, 3, as_msg(1, 0, ns, digest, [op(1, 0, name.encode())])))
    if result:
        print("result=%d" % result)
    else:
        ptype, value = bins[name]
        print("value=%s" % (value.decode() if ptype == 3 else value.hex()))
else:
    raise SystemExit("unknown command " + cmd)
PY
chmod 644 "$work/fixture/as.py"

cat >"$work/fixture/memory.conf" <<'CONF'
service {
    cluster-name verity
}

logging {
    console {
        context any info
    }
}

network {
    service {
        address any
        port 3000
    }

    heartbeat {
        mode mesh
        address local
        port 3002
        interval 150
        timeout 10
    }

    fabric {
        address local
        port 3001
    }
}

namespace mem {
    replication-factor 1

    storage-engine memory {
        data-size 1G
    }
}
CONF
# The same file with a misspelled namespace parameter.
sed 's/replication-factor 1/replication-factr 1/' "$work/fixture/memory.conf" >"$work/fixture/bad.conf"
chmod 644 "$work/fixture/memory.conf" "$work/fixture/bad.conf"
chmod 755 "$work/fixture"

# client CONTAINER ARGS...: run as.py inside CONTAINER's network namespace.
client() {
  target=$1
  shift
  docker run --rm --label "$label" --network "container:$target" --read-only \
    --cap-drop=ALL --user 65532:65532 -v "$work/fixture:/fixture:ro" \
    --entrypoint python3 "$python_image" /fixture/as.py "$@"
}

# wait_ready CONTAINER: poll the info port until asd answers "status ok".
wait_ready() {
  i=0
  until [ "$(client "$1" info 3000 status 2>/dev/null)" = "$(printf 'status\tok')" ]; do
    i=$((i + 1))
    if [ "$i" -gt 60 ] || [ "$(docker inspect -f '{{.State.Running}}' "$1")" != true ]; then
      docker logs "$1" >&2 || true
      fail "asd in $1 did not answer the info protocol on port 3000"
    fi
    sleep 1
  done
}

info_value() {
  printf '%s\n' "$1" | awk -F '\t' -v key="$2" '$1 == key { print $2 }'
}

# Positive: an in-memory namespace from a mounted config.
docker run -d --name "$memory" --label "$label" \
  -v "$work/fixture:/fixture:ro" "$image" --config-file /fixture/memory.conf >/dev/null ||
  fail 'could not start asd with the in-memory config'
wait_ready "$memory"

info=$(client "$memory" info 3000 build edition namespaces service-clear-std) ||
  fail 'info request failed'
printf '%s\n' "$info"
[ "$(info_value "$info" build)" = "$version" ] ||
  fail "info build is not $version"
[ "$(info_value "$info" edition)" = 'Aerospike Community Edition' ] ||
  fail 'info edition is not Aerospike Community Edition'
[ "$(info_value "$info" namespaces)" = mem ] ||
  fail 'info namespaces is not exactly mem'
case $(info_value "$info" service-clear-std) in
  *:3000*) ;;
  *) fail 'service-clear-std does not advertise port 3000' ;;
esac
client "$memory" connect 3001 || fail 'fabric port 3001 is not listening'
client "$memory" connect 3002 || fail 'heartbeat port 3002 is not listening'

digest=0123456789abcdef0123456789abcdef01234567
[ "$(client "$memory" put 3000 mem "$digest" greeting hello-memory)" = result=0 ] ||
  fail 'write to the in-memory namespace failed'
[ "$(client "$memory" get 3000 mem "$digest" greeting)" = value=hello-memory ] ||
  fail 'read back from the in-memory namespace failed'
[ "$(client "$memory" get 3000 mem fedcba9876543210fedcba9876543210fedcba98 greeting)" = result=2 ] ||
  fail 'missing record did not return KEY_NOT_FOUND (2)'
docker logs "$memory" 2>&1 | grep -q 'service ready: soon there will be cake!' ||
  fail 'asd did not log service readiness'
docker rm -f "$memory" >/dev/null

# Negative: an invalid config must stop asd with a parse error, not start it.
status=0
bad=$(timeout 60 docker run --rm --name "$invalid" --label "$label" --network none \
  -v "$work/fixture:/fixture:ro" "$image" --config-file /fixture/bad.conf 2>&1) || status=$?
printf '%s\n' "$bad" | tail -3
case $status in
  0) fail 'asd accepted an invalid config' ;;
  124) fail 'asd kept running with an invalid config' ;;
esac
printf '%s\n' "$bad" | grep -q 'replication-factr' ||
  fail 'asd did not name the invalid parameter'

# Default config: namespace "test" on the device file under /opt/aerospike/data
# survives a SIGTERM shutdown and a restart on the same volume.
docker volume create --label "$label" "$volume" >/dev/null
docker run -d --name "$disk" --label "$label" -v "$volume:/opt/aerospike/data" "$image" >/dev/null ||
  fail 'could not start asd with the default config'
wait_ready "$disk"
[ "$(info_value "$(client "$disk" info 3000 namespaces)" namespaces)" = test ] ||
  fail 'default config does not serve namespace test'
[ "$(client "$disk" put 3000 test "$digest" greeting hello-disk)" = result=0 ] ||
  fail 'write to the default namespace failed'
docker stop -t 60 "$disk" >/dev/null
exit_code=$(docker inspect -f '{{.State.ExitCode}}' "$disk")
[ "$exit_code" -eq 0 ] || {
  docker logs "$disk" >&2
  fail "asd exited $exit_code after SIGTERM"
}
docker logs "$disk" 2>&1 | grep -q 'finished clean shutdown' ||
  fail 'asd did not log a clean shutdown'
docker rm "$disk" >/dev/null
docker run --rm --label "$label" --network none --user 65532:65532 \
  -v "$volume:/opt/aerospike/data:ro" --entrypoint python3 "$python_image" \
  -c 'import os, sys; sys.exit(os.path.getsize("/opt/aerospike/data/test.dat") == 0)' ||
  fail 'default namespace did not create /opt/aerospike/data/test.dat'

docker run -d --name "$disk" --label "$label" -v "$volume:/opt/aerospike/data" "$image" >/dev/null ||
  fail 'could not restart asd on the existing data volume'
wait_ready "$disk"
[ "$(client "$disk" get 3000 test "$digest" greeting)" = value=hello-disk ] ||
  fail 'record did not survive a restart on the data volume'

printf 'aerospike %s smoke test passed\n' "$version"
