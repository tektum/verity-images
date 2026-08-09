#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE [FLAVOR]}
flavor=${2:-plain}
work=$(mktemp -d)
api_pid=
container=

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

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = '65534:65534' ] ||
  fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["python","-u","-m","sidecar"]' ] ||
  fail 'unexpected entrypoint'

arch=$(docker image inspect --format '{{.Architecture}}' "$image")
case $arch in amd64 | arm64) ;; *) fail "unsupported candidate architecture $arch" ;; esac

# Fake Kubernetes API: serves one labeled ConfigMap on LIST and records webhook calls.
cat > "$work/api.py" <<'PY'
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CONFIGMAP_LIST = {
    "apiVersion": "v1",
    "kind": "ConfigMapList",
    "metadata": {"resourceVersion": "1"},
    "items": [
        {
            "metadata": {
                "name": "sidecar-fixture",
                "namespace": "default",
                "resourceVersion": "1",
                "labels": {"app": "sidecar-test"},
            },
            "data": {"hello.txt": "world"},
        }
    ],
}

EMPTY_LIST = {"apiVersion": "v1", "kind": "List", "items": [], "metadata": {"resourceVersion": "1"}}


class Handler(BaseHTTPRequestHandler):
    def send_json(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/api/v1/namespaces/default/configmaps":
            return self.send_json(200, CONFIGMAP_LIST)
        return self.send_json(200, EMPTY_LIST)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        self.rfile.read(length)
        if self.path == "/webhook":
            with open(sys.argv[2], "a", encoding="utf-8") as marker:
                marker.write("called\n")
        self.send_json(200, {})

    def log_message(self, _format, *_args):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w", encoding="utf-8") as port_file:
    port_file.write(str(server.server_port))
server.serve_forever()
PY

python3 "$work/api.py" "$work/port" "$work/webhook-called" &
api_pid=$!
while [ ! -s "$work/port" ]; do
  kill -0 "$api_pid" 2>/dev/null || fail 'fake Kubernetes API failed to start'
done
port=$(cat "$work/port")

# The sidecar reads ~/.kube/config only (HOME-relative); it ignores KUBECONFIG.
mkdir -p "$work/home/.kube" "$work/serviceaccount" "$work/data"
cat > "$work/home/.kube/config" <<EOF
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
printf 'default' > "$work/serviceaccount/namespace"
chmod -R a+rX "$work/home" "$work/serviceaccount"
chmod 0777 "$work/data"

docker run --rm --network host \
  -e LABEL=app \
  -e FOLDER=/data \
  -e METHOD=LIST \
  -e RESOURCE=configmap \
  -e NAMESPACE=default \
  -e REQ_URL="http://127.0.0.1:$port/webhook" \
  -e REQ_METHOD=POST \
  -e HOME=/home/tester \
  -v "$work/home:/home/tester:ro" \
  -v "$work/serviceaccount:/var/run/secrets/kubernetes.io/serviceaccount:ro" \
  -v "$work/data:/data" \
  "$image" >"$work/run.log" 2>&1
status=$?
[ "$status" -eq 0 ] || {
  cat "$work/run.log" >&2
  fail "sidecar exited $status on the happy path"
}

[ "$(cat "$work/data/hello.txt" 2>/dev/null || true)" = world ] ||
  fail 'sidecar did not write the expected file from the fake ConfigMap'

for _ in $(seq 1 50); do
  [ -s "$work/webhook-called" ] && break
  sleep 0.1
done
[ -s "$work/webhook-called" ] || {
  cat "$work/run.log" >&2
  fail 'sidecar did not call the webhook after writing files'
}

# Invalid environment: LABEL/FOLDER set but no reachable Kubernetes API and no
# kubeconfig. The client raises ConfigException before any file is written.
rm -f "$work/invalid.log"
if docker run --rm --network none \
  -e LABEL=app \
  -e FOLDER=/data \
  -e METHOD=LIST \
  "$image" >"$work/invalid.log" 2>&1
then
  cat "$work/invalid.log" >&2
  fail 'missing Kubernetes connection config unexpectedly succeeded'
fi
grep -q ConfigException "$work/invalid.log" || {
  cat "$work/invalid.log" >&2
  fail 'invalid environment did not fail with the expected ConfigException'
}

printf 'SMOKE PASS image=%s\n' "$image"
