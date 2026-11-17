#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
curl_index=docker.io/curlimages/curl:8.14.1@sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b
curl_image=
provider=secrets-store-csi-driver-provider-aws
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

# Upstream image contract: scratch image without USER (root), working
# directory /, ENTRYPOINT ["/bin/secrets-store-csi-driver-provider-aws"].
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

# The provider calls AWS APIs over TLS; the image must ship a CA bundle.
created=$(docker create "$image")
docker cp "$created:/etc/ssl/certs/ca-certificates.crt" - > "$work/certs.tar" ||
  fail 'CA bundle is missing'
[ "$(wc -c < "$work/certs.tar")" -gt 10000 ] || fail 'CA bundle is empty'
docker rm -f "$created" >/dev/null
created=

docker run --rm --network none "$image" --help > "$work/help" 2>&1 ||
  fail '--help exited non-zero'
grep -F -- '-provider-volume' "$work/help" >/dev/null || fail 'usage lacks -provider-volume'
grep -F -- '-driver-writes-secrets' "$work/help" >/dev/null || fail 'usage lacks -driver-writes-secrets'
version=$(sed -n "s/.*Starting $provider version \([^ ]*\)\$/\1/p" "$work/help" | sed -n 1p)
printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' ||
  fail "provider version was not stamped: '$version'"

mkdir -m 0777 "$work/providers" "$work/out"
mkdir "$work/sa"
printf 'smoke-token' > "$work/sa/token"
chmod 0644 "$work/sa/token"

# Negative: without in-cluster Kubernetes config the provider must exit non-zero.
if docker run --rm --network none -v "$work/providers:/var/run/secrets-store-csi-providers" \
  "$image" > "$work/nocluster" 2>&1; then
  fail 'provider started without in-cluster config'
fi
grep -F 'Can not get cluster config' "$work/nocluster" >/dev/null ||
  fail 'missing in-cluster config error was not reported'

# Negative: an unusable rendezvous directory must fail before serving.
if docker run --rm --network none "$image" --provider-volume=/nonexistent \
  > "$work/nodir" 2>&1; then
  fail 'provider started without a socket directory'
fi
grep -F 'Failed to listen on unix socket' "$work/nodir" >/dev/null ||
  fail 'socket listen error was not reported'

docker run --rm --network none -v "$work/providers:/p" --user 0 --entrypoint rm \
  "$curl_image" -f /p/aws.sock >/dev/null 2>&1 || true

# Positive: run as the image's default (root) user with the in-cluster
# service account layout, exactly as the upstream DaemonSet mounts it. The
# Version RPC never contacts the API server, so no network is attached.
container=$(docker run -d --network none \
  -e KUBERNETES_SERVICE_HOST=127.0.0.1 -e KUBERNETES_SERVICE_PORT=6443 \
  -v "$work/sa:/var/run/secrets/kubernetes.io/serviceaccount:ro" \
  -v "$work/providers:/var/run/secrets-store-csi-providers" \
  "$image")

socket="$work/providers/aws.sock"
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
grep -F "aws.sock" "$work/logs" >/dev/null || fail 'provider did not log its socket address'

# Upstream restricts the socket to its owner (root) with mode 0700.
[ "$(stat -c %a "$socket")" = 700 ] || fail "unexpected socket mode: $(stat -c %a "$socket")"

# Unary gRPC over the provider unix socket: HTTP/2 with a 5-byte length
# prefix. $1 method, $2 output name, $3 request bytes (printf format), $4 user.
grpc() {
  # shellcheck disable=SC2059
  printf "$3" > "$work/out/$2.req"
  docker run --rm --network none --user "$4" \
    -v "$work/providers:/p" -v "$work/out:/w" "$curl_image" \
    -sS --http2-prior-knowledge --unix-socket /p/aws.sock --max-time 10 \
    -H 'content-type: application/grpc' -H 'te: trailers' \
    -D "/w/$2.headers" --data-binary "@/w/$2.req" -o "/w/$2.body" \
    "http://localhost/v1alpha1.CSIDriverProvider/$1" > "$work/$2.log" 2>&1
}

status() {
  sed -n 's/^grpc-status: *\([0-9]*\).*/\1/Ip' "$work/out/$1.headers" | sed -n 1p
}

# VersionRequest{version: "v1alpha1"}: field 1, length 8.
grpc Version version '\000\000\000\000\012\012\010v1alpha1' 0 ||
  { cat "$work/version.log" >&2; fail 'Version RPC transport failed'; }
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
for number in (1, 2, 3):
    print(fields.get(number, ""))
PY
python3 "$work/decode.py" "$work/out/version.body" > "$work/version.fields" ||
  fail 'Version response is not a valid protobuf message'
[ "$(sed -n 1p "$work/version.fields")" = v1alpha1 ] ||
  fail "unexpected Version.version: $(sed -n 1p "$work/version.fields")"
[ "$(sed -n 2p "$work/version.fields")" = "$provider" ] ||
  fail "unexpected Version.runtime_name: $(sed -n 2p "$work/version.fields")"
[ "$(sed -n 3p "$work/version.fields")" = "$version" ] ||
  fail "unexpected Version.runtime_version: $(sed -n 3p "$work/version.fields")"

# Negative: a Mount without a target path is rejected by the provider.
grpc Mount mount '\000\000\000\000\000' 0 ||
  { cat "$work/mount.log" >&2; fail 'Mount RPC transport failed'; }
[ "$(status mount)" = 2 ] || fail "empty Mount returned grpc-status $(status mount)"
grep -Fi 'grpc-message: Missing mount path' "$work/out/mount.headers" >/dev/null ||
  fail 'empty Mount did not report the missing mount path'

# Negative: a Mount with malformed attributes is rejected before any AWS call.
grpc Mount badattr '\000\000\000\000\015\012\001{\032\010/tmp/mnt' 0 ||
  { cat "$work/badattr.log" >&2; fail 'malformed Mount RPC transport failed'; }
[ "$(status badattr)" = 2 ] || fail "malformed Mount returned grpc-status $(status badattr)"
grep -Fi 'failed to unmarshal attributes' "$work/out/badattr.headers" >/dev/null ||
  fail 'malformed Mount attributes were not rejected'

# Negative: unknown methods are not served.
grpc Unknown unknown '\000\000\000\000\000' 0 ||
  { cat "$work/unknown.log" >&2; fail 'unknown RPC transport failed'; }
[ "$(status unknown)" = 12 ] || fail "unknown method returned grpc-status $(status unknown)"

# Negative: the 0700 socket refuses a non-root client.
if grpc Version denied '\000\000\000\000\012\012\010v1alpha1' 65534:65534; then
  fail 'non-root client reached the root-only provider socket'
fi
grep -Ei 'permission denied|could not connect|couldn.t connect' "$work/denied.log" >/dev/null ||
  { cat "$work/denied.log" >&2; fail 'non-root client failed for an unexpected reason'; }

# SIGTERM triggers a graceful stop that exits zero and removes the socket.
docker stop -t 20 "$container" >/dev/null
[ "$(docker inspect -f '{{.State.ExitCode}}' "$container")" = 0 ] ||
  { docker logs "$container" >&2; fail 'provider did not exit cleanly on SIGTERM'; }
docker logs "$container" 2>&1 | grep -F 'received signal:terminated' >/dev/null ||
  fail 'provider did not log the termination signal'
[ ! -e "$socket" ] || fail 'provider left its socket behind after shutdown'

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$version"
