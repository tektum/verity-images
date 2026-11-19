#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE [FLAVOR]}
flavor=${2:-plain}
recipe="$(dirname "$0")/../melange.yaml"
version=$(sed -n 's/^  version: "\([0-9.]*\)".*$/\1/p' "$recipe")
work=$(mktemp -d)
api_pid=
container=
driver=csi.cert-manager.io
metrics_port=18096

cleanup() {
  if [ -n "$container" ]; then
    docker rm -f "$container" >/dev/null 2>&1 || true
  fi
  if [ -n "$api_pid" ]; then
    kill "$api_pid" >/dev/null 2>&1 || true
    wait "$api_pid" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

case $flavor in plain) ;; *) fail "unsupported flavor $flavor" ;; esac
[ -n "$version" ] || fail 'could not read the recipe version'

# Image contract: root node plugin, binary entrypoint, mount tools present.
[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 0 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/cert-manager-csi-driver"]' ] || fail 'unexpected entrypoint'
docker run --rm --network none "$image" --help >"$work/help" 2>&1 || fail '--help failed'
grep -qF -- '--data-root' "$work/help" || fail '--help does not list --data-root'
for tool in mount umount; do
  docker run --rm --network none --entrypoint "$tool" "$image" --version >/dev/null 2>&1 ||
    fail "$tool is missing"
done

# Negative: without cluster configuration the driver must fail fast and say why.
rc=0
timeout 60 docker run --rm --network none -e KUBECONFIG=/missing "$image" \
  --endpoint=unix:///tmp/csi.sock --node-id=smoke-node >"$work/nocfg.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'driver started without cluster configuration'
[ "$rc" -ne 124 ] || fail 'driver hung without cluster configuration'
grep -qiE 'kubeconfig|config' "$work/nocfg.log" ||
  { cat "$work/nocfg.log" >&2; fail 'missing configuration error is not readable'; }

cat > "$work/api.py" <<'PY'
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def resource_list(group, resources):
    return {
        "apiVersion": "v1",
        "groupVersion": group,
        "kind": "APIResourceList",
        "resources": [
            {
                "kind": kind,
                "name": name,
                "namespaced": True,
                "singularName": "",
                "verbs": ["create", "delete", "get", "list", "patch", "update", "watch"],
            }
            for name, kind in resources
        ],
    }


CORE = [("pods", "Pod"), ("events", "Event")]
GROUP = "cert-manager.io"
SSCSI = [("certificaterequests", "CertificateRequest")]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def send_json(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        query = self.path.partition("?")[2]
        if path == "/api":
            return self.send_json(200, {"kind": "APIVersions", "versions": ["v1"], "serverAddressByClientCIDRs": []})
        if path == "/api/v1":
            return self.send_json(200, resource_list("v1", CORE))
        if path == "/apis":
            version = {"groupVersion": GROUP + "/v1", "version": "v1"}
            group = {"name": GROUP, "preferredVersion": version, "versions": [version]}
            return self.send_json(200, {"apiVersion": "v1", "kind": "APIGroupList", "groups": [group]})
        if path == "/apis/" + GROUP + "/v1":
            return self.send_json(200, resource_list(GROUP + "/v1", SSCSI))
        if path == "/version":
            return self.send_json(200, {"gitVersion": "v1.34.0", "major": "1", "minor": "34"})
        if "watch=true" in query:
            # Watch-list clients wait for the initial-events-end bookmark; then
            # hold the watch open without events so informers stay synced.
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            if "sendInitialEvents=true" in query:
                kinds = {name: (kind, "v1") for name, kind in CORE}
                kinds.update({name: (kind, GROUP + "/v1") for name, kind in SSCSI})
                kind, api_version = kinds.get(path.rstrip("/").rsplit("/", 1)[-1], ("Status", "v1"))
                event = {
                    "type": "BOOKMARK",
                    "object": {
                        "apiVersion": api_version,
                        "kind": kind,
                        "metadata": {
                            "resourceVersion": "1",
                            "annotations": {"k8s.io/initial-events-end": "true"},
                        },
                    },
                }
                data = json.dumps(event).encode() + b"\n"
                self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
            self.wfile.flush()
            try:
                while self.rfile.read(1):
                    pass
            except OSError:
                pass
            return
        return self.send_json(200, {"apiVersion": "v1", "items": [], "kind": "List", "metadata": {"resourceVersion": "1"}})

    def log_message(self, _format, *_args):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
with open(sys.argv[1], "w", encoding="utf-8") as port_file:
    port_file.write(str(server.server_port))
server.serve_forever()
PY

python3 "$work/api.py" "$work/port" &
api_pid=$!
while [ ! -s "$work/port" ]; do
  kill -0 "$api_pid" 2>/dev/null || fail 'fake Kubernetes API failed to start'
  sleep 0.1
done
port=$(cat "$work/port")

cat > "$work/kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: smoke
    cluster:
      server: http://127.0.0.1:$port
contexts:
  - name: smoke
    context:
      cluster: smoke
      user: smoke
current-context: smoke
users:
  - name: smoke
    user:
      token: smoke
EOF
chmod 0644 "$work/kubeconfig"
mkdir -m 0777 "$work/csi"

# Run as the invoking user so the host-side client can connect to the socket.
# The driver keeps volume data on a tmpfs at <data-root>/inmemfs and mounts one
# only when none is present, so an engine tmpfs avoids CAP_SYS_ADMIN here.
# The data root is relative to the / working directory, as in the upstream chart
# (the driver reads it through os.DirFS("/"), which rejects absolute paths).
container=$(docker run -d --network host --user "$(id -u):$(id -g)" \
  -e KUBECONFIG=/tmp/kubeconfig \
  -v "$work/kubeconfig:/tmp/kubeconfig:ro" \
  -v "$work/csi:/csi" \
  --tmpfs "/csi-data-dir/inmemfs:uid=$(id -u),gid=$(id -g),mode=0700" \
  "$image" --endpoint=unix:///csi/csi.sock --node-id=smoke-node \
  --driver-name="$driver" --data-root=csi-data-dir --log-level=2 \
  --metrics-bind-address=127.0.0.1:$metrics_port)

# Minimal gRPC unary call over the CSI unix socket: HTTP/2 + 5-byte frame
# header for an empty request message.
grpc() {
  printf '\000\000\000\000\000' | curl -sS --http2-prior-knowledge \
    --unix-socket "$work/csi/csi.sock" --max-time 5 \
    -H 'content-type: application/grpc' -H 'te: trailers' \
    -D "$work/$2.headers" --data-binary @- -o "$work/$2.body" \
    "http://localhost/$1"
}

deadline=$(( $(date +%s) + 60 ))
until [ -S "$work/csi/csi.sock" ] && grpc csi.v1.Identity/Probe probe 2>/dev/null &&
  grep -qi '^grpc-status: 0' "$work/probe.headers"; do
  if [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)" != true ]; then
    docker logs "$container" >&2 || true
    fail 'driver exited before serving CSI'
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    docker logs "$container" >&2 || true
    fail 'CSI Identity Probe did not succeed'
  fi
  sleep 1
done

grpc csi.v1.Identity/GetPluginInfo info || fail 'GetPluginInfo call failed'
grep -qi '^grpc-status: 0' "$work/info.headers" || fail 'GetPluginInfo returned an error'
# Response: 5-byte frame header, then field 1 (name) = 0x0a <len> <name>.
od -An -tx1 -v "$work/info.body" | tr -d ' \n' > "$work/info.hex"
name_hex=$(printf '%s' "$driver" | od -An -tx1 -v | tr -d ' \n')
len_hex=$(printf '%02x' "${#driver}")
case "$(cat "$work/info.hex")" in
  00????????0a"$len_hex$name_hex"12*) ;;
  *) docker logs "$container" >&2 || true; fail 'GetPluginInfo returned an unexpected driver name' ;;
esac
grep -aF "v$version" "$work/info.body" >/dev/null || fail 'GetPluginInfo vendor version is not the recipe version'

grpc csi.v1.Node/NodeGetInfo nodeinfo || fail 'NodeGetInfo call failed'
grep -qi '^grpc-status: 0' "$work/nodeinfo.headers" || fail 'NodeGetInfo returned an error'
grep -aF 'smoke-node' "$work/nodeinfo.body" >/dev/null || fail 'NodeGetInfo node id mismatch'

# Negative: an unknown RPC must be rejected as Unimplemented (12).
grpc csi.v1.Identity/DoesNotExist bogus || fail 'unknown RPC call failed at transport'
grep -qi '^grpc-status: 12' "$work/bogus.headers" || fail 'unknown RPC was not rejected'

curl -fsS "http://127.0.0.1:$metrics_port/metrics" > "$work/metrics" ||
  fail 'metrics endpoint is unavailable'
grep -q '^go_goroutines ' "$work/metrics" || fail 'metrics payload is invalid'

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$version"
