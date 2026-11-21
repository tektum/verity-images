#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
curl_index=docker.io/curlimages/curl:8.14.1@sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b
curl_image=
provider=secrets-store-csi-driver-provider-gcp
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

# Upstream image contract: distroless/static without USER (root), working
# directory /, ENTRYPOINT ["/bin/secrets-store-csi-driver-provider-gcp"].
user=$(docker image inspect -f '{{.Config.User}}' "$image")
case "$user" in
  '' | 0 | root | 0:0) ;;
  *) fail "unexpected OCI user: $user" ;;
esac
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = "[\"/bin/$provider\"]" ] ||
  fail 'unexpected entrypoint'
[ "$(docker image inspect -f '{{json .Config.Cmd}}' "$image")" = null ] ||
  fail 'unexpected default command'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = / ] ||
  fail 'unexpected working directory'

# The provider calls Google APIs over TLS; the image must ship a CA bundle.
created=$(docker create "$image")
docker cp "$created:/etc/ssl/certs/ca-certificates.crt" - > "$work/certs.tar" ||
  fail 'CA bundle is missing'
[ "$(wc -c < "$work/certs.tar")" -gt 10000 ] || fail 'CA bundle is empty'
docker rm -f "$created" >/dev/null
created=

docker run --rm --network none "$image" -help > "$work/help" 2>&1 ||
  fail '-help exited non-zero'
for flag in -kubeconfig -metrics_addr -log-format-json -sm_connection_pool_size -iam_connection_pool_size; do
  grep -F -- "$flag" "$work/help" >/dev/null || fail "usage lacks $flag"
done

# Negative: unknown flags are rejected.
if docker run --rm --network none "$image" -no-such-flag > "$work/badflag" 2>&1; then
  fail 'unknown flag unexpectedly succeeded'
fi
grep -F 'flag provided but not defined' "$work/badflag" >/dev/null || fail 'unknown flag error was not reported'

mkdir -m 0777 "$work/providers" "$work/out"
mkdir "$work/sa"
printf 'smoke-token' > "$work/sa/token"
printf 'default' > "$work/sa/namespace"
chmod 0644 "$work/sa/token" "$work/sa/namespace"

# Negative: without in-cluster Kubernetes config or a kubeconfig it must exit non-zero.
if docker run --rm --network none -e TARGET_DIR=/p -v "$work/providers:/p" \
  "$image" > "$work/nocluster" 2>&1; then
  fail 'provider started without cluster config'
fi
grep -F 'failed to read kubeconfig' "$work/nocluster" >/dev/null ||
  fail 'missing cluster config error was not reported'

# Negative: an unusable socket directory must fail before serving.
if docker run --rm --network none -e TARGET_DIR=/nonexistent \
  -e KUBERNETES_SERVICE_HOST=127.0.0.1 -e KUBERNETES_SERVICE_PORT=6443 \
  -v "$work/sa:/var/run/secrets/kubernetes.io/serviceaccount:ro" \
  "$image" > "$work/nodir" 2>&1; then
  fail 'provider started without a socket directory'
fi
grep -F 'unable to listen to unix socket' "$work/nodir" >/dev/null ||
  fail 'socket listen error was not reported'

# Positive: in-cluster service account layout and TARGET_DIR as the upstream
# DaemonSet sets them. No network is attached, so nothing can reach Google or
# the Kubernetes API.
container=$(docker run -d --network none -e TARGET_DIR=/etc/kubernetes/secrets-store-csi-providers \
  -e KUBERNETES_SERVICE_HOST=127.0.0.1 -e KUBERNETES_SERVICE_PORT=6443 \
  -v "$work/sa:/var/run/secrets/kubernetes.io/serviceaccount:ro" \
  -v "$work/providers:/etc/kubernetes/secrets-store-csi-providers" \
  "$image")

socket="$work/providers/gcp.sock"
deadline=$(( $(date +%s) + 60 ))
until [ -S "$socket" ]; do
  if [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)" != true ]; then
    docker logs "$container" >&2 2>&1 || true
    fail 'provider exited before creating its socket'
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    docker logs "$container" >&2 2>&1 || true
    fail 'provider socket was not created'
  fi
  sleep 1
done
docker logs "$container" > "$work/logs" 2>&1 || true
version=$(sed -n "s/.*starting $provider\/v\([0-9][0-9.]*\).*/\1/p" "$work/logs" | sed -n 1p)
printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' ||
  { cat "$work/logs" >&2; fail "provider version was not stamped: '$version'"; }

# Unary gRPC over the provider unix socket: HTTP/2 with a 5-byte length
# prefix. $1 method, $2 output name (request in $work/out/$2.req), $3 user.
grpc() {
  docker run --rm --network none --user "$3" \
    -v "$work/providers:/p" -v "$work/out:/w" "$curl_image" \
    -sS --http2-prior-knowledge --unix-socket /p/gcp.sock --max-time 20 \
    -H 'content-type: application/grpc' -H 'te: trailers' \
    -D "/w/$2.headers" --data-binary "@/w/$2.req" -o "/w/$2.body" \
    "http://localhost/v1alpha1.CSIDriverProvider/$1" > "$work/$2.log" 2>&1
}

status() {
  sed -n 's/^grpc-status: *\([0-9]*\).*/\1/Ip' "$work/out/$1.headers" | sed -n 1p
}

# Request encoder: string fields of a protobuf message in a gRPC frame.
cat > "$work/encode.py" <<'PY'
import sys


def varint(n):
    out = b""
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out += bytes([b | 0x80])
        else:
            return out + bytes([b])


msg = b""
for arg in sys.argv[2:]:
    number, value = arg.split("=", 1)
    data = value.encode()
    msg += varint(int(number) << 3 | 2) + varint(len(data)) + data
open(sys.argv[1], "wb").write(b"\0" + len(msg).to_bytes(4, "big") + msg)
PY

# VersionRequest{version: "v1alpha1"}.
python3 "$work/encode.py" "$work/out/version.req" 1=v1alpha1
grpc Version version 0 || { cat "$work/version.log" >&2; fail 'Version RPC transport failed'; }
[ "$(status version)" = 0 ] || fail "Version RPC returned grpc-status $(status version)"

cat > "$work/decode.py" <<'PY'
import sys

data = open(sys.argv[1], "rb").read()
if len(data) < 5 or data[0] != 0 or int.from_bytes(data[1:5], "big") != len(data) - 5:
    sys.exit("malformed gRPC frame")
msg, pos, fields = data[5:], 0, {}
while pos < len(msg):
    key = msg[pos]
    pos += 1
    if key & 7 != 2:
        sys.exit("unexpected wire type")
    size = 0
    shift = 0
    while True:
        byte = msg[pos]
        pos += 1
        size |= (byte & 0x7F) << shift
        shift += 7
        if not byte & 0x80:
            break
    fields[key >> 3] = msg[pos:pos + size].decode()
    pos += size
for number in (1, 2):
    print(fields.get(number, ""))
PY
python3 "$work/decode.py" "$work/out/version.body" > "$work/version.fields" ||
  fail 'Version response is not a valid protobuf message'
[ "$(sed -n 1p "$work/version.fields")" = v1alpha1 ] ||
  fail "unexpected Version.version: $(sed -n 1p "$work/version.fields")"
[ "$(sed -n 2p "$work/version.fields")" = "$provider" ] ||
  fail "unexpected Version.runtime_name: $(sed -n 2p "$work/version.fields")"

# Negative: a Mount with an unparsable permission is rejected.
python3 "$work/encode.py" "$work/out/badperm.req" 3=/tmp/mnt 4=not-a-number
grpc Mount badperm 0 || { cat "$work/badperm.log" >&2; fail 'Mount RPC transport failed'; }
[ "$(status badperm)" = 3 ] || fail "bad permission Mount returned grpc-status $(status badperm)"
grep -Fi 'grpc-message: Unable to parse permissions' "$work/out/badperm.headers" >/dev/null ||
  fail 'bad permission was not reported'

# Negative: malformed attributes are rejected before any credential lookup.
python3 "$work/encode.py" "$work/out/badattr.req" '1={' 3=/tmp/mnt 4=420
grpc Mount badattr 0 || { cat "$work/badattr.log" >&2; fail 'malformed Mount RPC transport failed'; }
[ "$(status badattr)" = 3 ] || fail "malformed Mount returned grpc-status $(status badattr)"
grep -Fi 'failed to unmarshal attributes' "$work/out/badattr.headers" >/dev/null ||
  fail 'malformed Mount attributes were not rejected'

# A well-formed Mount needs pod credentials from the Kubernetes API, which is
# unreachable offline: it must fail fast with PermissionDenied, not hang.
attributes='{"csi.storage.k8s.io/pod.name":"smoke","csi.storage.k8s.io/pod.namespace":"default",'
attributes="$attributes"'"csi.storage.k8s.io/pod.uid":"00000000-0000-0000-0000-000000000001",'
attributes="$attributes"'"csi.storage.k8s.io/serviceAccount.name":"default",'
attributes="$attributes"'"secrets":"- resourceName: projects/verity-smoke/secrets/smoke/versions/latest\n  path: smoke.txt\n"}'
python3 "$work/encode.py" "$work/out/mount.req" "1=$attributes" '2={}' 3=/tmp/mnt 4=420
start=$(date +%s)
grpc Mount mount 0 || { cat "$work/mount.log" >&2; fail 'Mount RPC transport failed'; }
[ "$(status mount)" = 7 ] || { cat "$work/out/mount.headers" >&2; fail "offline Mount returned grpc-status $(status mount)"; }
grep -Fi 'grpc-message: unable to obtain auth for mount' "$work/out/mount.headers" >/dev/null ||
  fail 'offline Mount did not report the credential failure'
[ $(( $(date +%s) - start )) -lt 20 ] || fail 'offline Mount did not fail fast'

# Negative: unknown methods are not served.
python3 "$work/encode.py" "$work/out/unknown.req"
grpc Unknown unknown 0 || { cat "$work/unknown.log" >&2; fail 'unknown RPC transport failed'; }
[ "$(status unknown)" = 12 ] || fail "unknown method returned grpc-status $(status unknown)"

# SIGTERM triggers a graceful stop that exits zero.
docker stop -t 20 "$container" >/dev/null
[ "$(docker inspect -f '{{.State.ExitCode}}' "$container")" = 0 ] ||
  { docker logs "$container" >&2; fail 'provider did not exit cleanly on SIGTERM'; }

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$version"
