#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
curl_index=docker.io/curlimages/curl:8.14.1@sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b
curl_image=
provider=secrets-store-csi-driver-provider-azure
work=$(mktemp -d)
container=
created=

cleanup() {
  if [ -n "$container" ]; then
    docker rm -f "$container" >/dev/null 2>&1 || true
  fi
  if [ -n "$created" ]; then
    docker rm -f "$created" >/dev/null 2>&1 || true
  fi
  # Files written by root containers live in host-user-owned directories.
  rm -rf "$work" 2>/dev/null || docker run --rm --network none --user 0 \
    --entrypoint rm -v "$work:/w" "$curl_image" -rf /w/providers /w/out >/dev/null 2>&1 || true
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# pull_child INDEX: pull the pinned index by its per-platform child digest,
# verifying the index bytes against the pin first so the pin stays authoritative.
# Pulling the index itself for a second platform fails with "cannot overwrite digest".
image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
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
curl_image=$(pull_child "$curl_index")

# Upstream image contract (mcr.microsoft.com/oss/v2/azure/secrets-store/provider-azure):
# no USER (root), working directory /, ENTRYPOINT ["/secrets-store-csi-driver-provider-azure"]
# and no default command; the chart passes only flags.
user=$(docker image inspect -f '{{.Config.User}}' "$image")
case "$user" in
  '' | 0 | root | 0:0) ;;
  *) fail "unexpected OCI user: $user" ;;
esac
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = "[\"/$provider\"]" ] ||
  fail 'unexpected entrypoint'
[ "$(docker image inspect -f '{{json .Config.Cmd}}' "$image")" = null ] ||
  fail 'unexpected default command'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = / ] ||
  fail 'unexpected working directory'

# The provider calls Azure Key Vault and Entra ID over TLS; the image must ship a CA bundle.
created=$(docker create "$image")
docker cp "$created:/etc/ssl/certs/ca-certificates.crt" - > "$work/certs.tar" ||
  fail 'CA bundle is missing'
[ "$(wc -c < "$work/certs.tar")" -gt 10000 ] || fail 'CA bundle is empty'
docker rm -f "$created" >/dev/null
created=

# Version output: upstream PrintVersion JSON with the Makefile ldflags stamps.
docker run --rm --network none "$image" --version > "$work/version.json" 2>&1 ||
  { cat "$work/version.json" >&2; fail '--version exited non-zero'; }
version=$(jq -er '.version' "$work/version.json") || fail 'version output is not JSON with .version'
printf '%s\n' "$version" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' ||
  fail "provider version was not stamped: '$version'"
jq -er '.buildDate' "$work/version.json" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{2}:[0-9]{2}$' ||
  fail "build date was not stamped: $(cat "$work/version.json")"

# The binary is also reachable at the upstream Dockerfile path (/bin) and by
# name through PATH, as the upstream Dockerfile ENTRYPOINT invokes it.
for entry in /bin/$provider /usr/bin/$provider $provider; do
  out=$(docker run --rm --network none --entrypoint "$entry" "$image" --version 2>&1) ||
    fail "$entry --version exited non-zero"
  [ "$out" = "$(cat "$work/version.json")" ] || fail "$entry reports a different version: $out"
done

# Negative flags.
if docker run --rm --network none "$image" --no-such-flag > "$work/badflag" 2>&1; then
  fail 'provider accepted an unknown flag'
fi
grep -F 'flag provided but not defined: -no-such-flag' "$work/badflag" >/dev/null ||
  fail 'unknown flag was not reported'

if docker run --rm --network none "$image" --cloud-name=NoSuchCloud > "$work/badcloud" 2>&1; then
  fail 'provider accepted an unknown default cloud'
fi
grep -F 'failed validating default cloud environment' "$work/badcloud" >/dev/null ||
  fail 'unknown default cloud was not reported'

if docker run --rm --network none "$image" --endpoint=azure.sock > "$work/badendpoint" 2>&1; then
  fail 'provider accepted an endpoint without a scheme'
fi
grep -F 'invalid endpoint: azure.sock' "$work/badendpoint" >/dev/null ||
  fail 'invalid endpoint was not reported'

if docker run --rm --network none "$image" --endpoint=unix:///nonexistent/azure.sock \
  > "$work/nodir" 2>&1; then
  fail 'provider started without a socket directory'
fi
grep -F 'failed to listen' "$work/nodir" >/dev/null || fail 'socket listen error was not reported'

mkdir -m 0777 "$work/providers" "$work/out"

# Positive: the chart's flags, run as the image's default (root) user with no
# network and no Azure credentials. Version, Mount validation, and the health
# checks never leave the node.
container=$(docker run -d --network none \
  -v "$work/providers:/provider" \
  "$image" --endpoint=unix:///provider/azure.sock \
  --healthz-port=8989 --healthz-path=/healthz --healthz-timeout=5s)

socket="$work/providers/azure.sock"
deadline=$(( $(date +%s) + 60 ))
until [ -S "$socket" ] && grep -F 'Listening for connections' "$work/logs" >/dev/null 2>&1; do
  docker logs "$container" > "$work/logs" 2>&1 || true
  if [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)" != true ]; then
    cat "$work/logs" >&2
    fail 'provider exited before creating its socket'
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    cat "$work/logs" >&2
    fail 'provider socket was not created'
  fi
  sleep 1
done
grep -F "Starting Azure Key Vault Provider\" version=\"$version\"" "$work/logs" >/dev/null ||
  fail 'provider did not log its stamped version at startup'
grep -F '/provider/azure.sock' "$work/logs" >/dev/null || fail 'provider did not log its socket address'

# Upstream sets umask 0077 around Listen, so only root can reach the socket.
[ "$(stat -c %a "$socket")" = 700 ] || fail "unexpected socket mode: $(stat -c %a "$socket")"

# Unary gRPC over the provider unix socket: HTTP/2 with a 5-byte length
# prefix. $1 path, $2 output name, $3 user; request bytes in $work/out/$2.req.
grpc() {
  docker run --rm --network none --user "$3" \
    -v "$work/providers:/p" -v "$work/out:/w" "$curl_image" \
    -sS --http2-prior-knowledge --unix-socket /p/azure.sock --max-time 10 \
    -H 'content-type: application/grpc' -H 'te: trailers' \
    -D "/w/$2.headers" --data-binary "@/w/$2.req" -o "/w/$2.body" \
    "http://localhost/$1" > "$work/$2.log" 2>&1
}

status() {
  sed -n 's/^grpc-status: *\([0-9]*\).*/\1/Ip' "$work/out/$1.headers" | sed -n 1p
}

# Protobuf helpers: "encode NAME FIELD=VALUE..." writes a framed message of
# length-delimited string fields; "decode FILE" prints string fields 1-3.
cat > "$work/pb.py" <<'PY'
import sys


def varint(n):
    out = b""
    while True:
        byte = n & 0x7F
        n >>= 7
        if n:
            out += bytes([byte | 0x80])
        else:
            return out + bytes([byte])


if sys.argv[1] == "encode":
    msg = b""
    for arg in sys.argv[3:]:
        number, value = arg.split("=", 1)
        data = value.encode()
        msg += varint(int(number) << 3 | 2) + varint(len(data)) + data
    with open(sys.argv[2], "wb") as out:
        out.write(b"\0" + len(msg).to_bytes(4, "big") + msg)
    sys.exit(0)

data = open(sys.argv[2], "rb").read()
if len(data) < 5 or data[0] != 0 or int.from_bytes(data[1:5], "big") != len(data) - 5:
    sys.exit("malformed gRPC frame")
msg, pos, fields = data[5:], 0, {}
while pos < len(msg):
    key = msg[pos]
    pos += 1
    value = 0
    shift = 0
    while True:
        byte = msg[pos]
        pos += 1
        value |= (byte & 0x7F) << shift
        shift += 7
        if not byte & 0x80:
            break
    if key & 7 == 0:
        fields[key >> 3] = str(value)
    elif key & 7 == 2:
        fields[key >> 3] = msg[pos:pos + value].decode()
        pos += value
    else:
        sys.exit("unexpected wire type")
for number in (1, 2, 3):
    print(fields.get(number, ""))
PY
encode() {
  name=$1
  shift
  python3 "$work/pb.py" encode "$work/out/$name.req" "$@" || fail "cannot encode $name request"
}

# VersionRequest{version: "v1alpha1"}.
encode version 1=v1alpha1
grpc v1alpha1.CSIDriverProvider/Version version 0 ||
  { cat "$work/version.log" >&2; fail 'Version RPC transport failed'; }
[ "$(status version)" = 0 ] || fail "Version RPC returned grpc-status $(status version)"
python3 "$work/pb.py" decode "$work/out/version.body" > "$work/version.fields" ||
  fail 'Version response is not a valid protobuf message'
[ "$(sed -n 1p "$work/version.fields")" = v1alpha1 ] ||
  fail "unexpected Version.version: $(sed -n 1p "$work/version.fields")"
[ "$(sed -n 2p "$work/version.fields")" = "$provider" ] ||
  fail "unexpected Version.runtime_name: $(sed -n 2p "$work/version.fields")"
[ "$(sed -n 3p "$work/version.fields")" = "$version" ] ||
  fail "unexpected Version.runtime_version: $(sed -n 3p "$work/version.fields")"

# grpc.health.v1.Health/Check reports SERVING (enum 1) on the same socket.
encode health
grpc grpc.health.v1.Health/Check health 0 ||
  { cat "$work/health.log" >&2; fail 'Health Check RPC transport failed'; }
[ "$(status health)" = 0 ] || fail "Health Check returned grpc-status $(status health)"
python3 "$work/pb.py" decode "$work/out/health.body" > "$work/health.fields" ||
  fail 'Health Check response is not a valid protobuf message'
[ "$(sed -n 1p "$work/health.fields")" = 1 ] ||
  fail "Health Check status is not SERVING: $(sed -n 1p "$work/health.fields")"

# mount NAME ATTRIBUTES MESSAGE: MountRequest{attributes, secrets: "{}",
# target_path, permission: "420"} must fail with grpc-status 2 and MESSAGE.
mount() {
  encode "$1" "1=$2" '2={}' 3=/tmp/mnt 4=420
  grpc v1alpha1.CSIDriverProvider/Mount "$1" 0 ||
    { cat "$work/$1.log" >&2; fail "Mount RPC $1 transport failed"; }
  [ "$(status "$1")" = 2 ] || fail "Mount $1 returned grpc-status $(status "$1")"
  grep -Fi "grpc-message: $3" "$work/out/$1.headers" >/dev/null ||
    { cat "$work/out/$1.headers" >&2; fail "Mount $1 did not report: $3"; }
}

# Negative: a Mount without attributes is rejected before any Azure call.
encode mount
grpc v1alpha1.CSIDriverProvider/Mount mount 0 ||
  { cat "$work/mount.log" >&2; fail 'Mount RPC transport failed'; }
[ "$(status mount)" = 2 ] || fail "empty Mount returned grpc-status $(status mount)"
grep -Fi 'grpc-message: failed to unmarshal attributes' "$work/out/mount.headers" >/dev/null ||
  { cat "$work/out/mount.headers" >&2; fail 'empty Mount attributes were not rejected'; }

mount badattr '{' 'failed to unmarshal attributes'
mount nopod '{}' 'failed to mount objects, error: pod name is not provided'
pod='"csi.storage.k8s.io/pod.name":"app","csi.storage.k8s.io/pod.namespace":"default"'
mount twoidentities "{$pod,\"usePodIdentity\":\"true\",\"useVMManagedIdentity\":\"true\"}" \
  'failed to mount objects, error: only one identity mode can be enabled at a time'
mount novault "{$pod}" 'failed to mount objects, error: keyvaultName is not provided'
mount notenant "{$pod,\"keyvaultName\":\"smoke-kv\"}" \
  'failed to mount objects, error: tenantId is not provided'
docker logs "$container" 2>&1 | grep -F 'failed to process mount request' >/dev/null ||
  fail 'provider did not log the rejected mount requests'

# Negative: unknown methods are not served.
encode unknown
grpc v1alpha1.CSIDriverProvider/Unknown unknown 0 ||
  { cat "$work/unknown.log" >&2; fail 'unknown RPC transport failed'; }
[ "$(status unknown)" = 12 ] || fail "unknown method returned grpc-status $(status unknown)"

# Negative: the 0700 socket refuses a non-root client.
cp "$work/out/version.req" "$work/out/denied.req"
if grpc v1alpha1.CSIDriverProvider/Version denied 65534:65534; then
  fail 'non-root client reached the root-only provider socket'
fi
grep -Ei 'permission denied|could not connect|couldn.t connect' "$work/denied.log" >/dev/null ||
  { cat "$work/denied.log" >&2; fail 'non-root client failed for an unexpected reason'; }

# HTTP liveness endpoint (--healthz-port/--healthz-path): it dials the socket
# and runs the gRPC health check. The client joins the provider's otherwise
# isolated network namespace.
healthz() {
  docker run --rm --network "container:$container" "$curl_image" \
    -sS --max-time 10 -o /dev/stdout -w '\n%{http_code}' "http://127.0.0.1:8989$1" 2>&1
}
deadline=$(( $(date +%s) + 30 ))
until out=$(healthz /healthz) && [ "$(printf '%s\n' "$out" | tail -n 1)" = 200 ]; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    printf '%s\n' "$out" >&2
    fail 'healthz endpoint did not answer 200'
  fi
  sleep 1
done
[ "$(printf '%s\n' "$out" | sed -n 1p)" = ok ] || fail "unexpected healthz body: $out"
out=$(healthz /nothere) || fail 'healthz server transport failed'
[ "$(printf '%s\n' "$out" | tail -n 1)" = 404 ] || fail "unexpected status for an unknown path: $out"

# SIGTERM triggers a graceful stop that exits zero and removes the socket.
docker stop -t 20 "$container" >/dev/null
[ "$(docker inspect -f '{{.State.ExitCode}}' "$container")" = 0 ] ||
  { docker logs "$container" >&2; fail 'provider did not exit cleanly on SIGTERM'; }
docker logs "$container" 2>&1 | grep -F 'terminating the server' >/dev/null ||
  fail 'provider did not log the graceful shutdown'
[ ! -e "$socket" ] || fail 'provider left its socket behind after shutdown'

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$version"
