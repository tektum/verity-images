#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE [FLAVOR]}
flavor=${2:-plain}
work=$(mktemp -d)
api_pid=
container=verity-kubernetes-reflector-$$
invalid_container=$container-invalid

cleanup() {
  docker rm -f "$container" "$invalid_container" >/dev/null 2>&1 || true
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

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = app ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["dotnet","ES.Kubernetes.Reflector.dll"]' ] ||
  fail 'unexpected entrypoint'
[ "$(docker image inspect -f '{{json .Config.Cmd}}' "$image")" = null ] || fail 'unexpected command'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /app ] || fail 'unexpected working directory'
docker image inspect -f '{{json .Config.ExposedPorts}}' "$image" | grep -qx '{"8080/tcp":{}}' ||
  fail 'port 8080 is not exposed'

cat > "$work/api.py" <<'PY'
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        path = urlsplit(self.path).path
        if path.rstrip("/") == "/version":
            body = json.dumps({"gitVersion": "v1.30.0"}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        kinds = {
            "/api/v1/namespaces": "Namespace",
            "/api/v1/secrets": "Secret",
            "/api/v1/configmaps": "ConfigMap",
        }
        kind = kinds.get(path)
        if kind is None:
            self.send_error(404)
            return
        metadata = {
            "name": "default" if kind == "Namespace" else "fixture",
            "resourceVersion": "1",
            "annotations": {},
        }
        if kind != "Namespace":
            metadata["namespace"] = "default"
        resource = {"apiVersion": "v1", "kind": kind, "metadata": metadata}
        if kind in {"Secret", "ConfigMap"}:
            resource["data"] = {}
        if kind == "Secret":
            resource["type"] = "Opaque"
        body = (json.dumps({
            "type": "ADDED",
            "object": resource,
        }) + "\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()
        time.sleep(60)

    def log_message(self, _format, *_args):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w", encoding="utf-8") as port_file:
    port_file.write(str(server.server_port))
server.serve_forever()
PY

python3 "$work/api.py" "$work/api-port" &
api_pid=$!
while [ ! -s "$work/api-port" ]; do
  kill -0 "$api_pid" 2>/dev/null || fail 'fake Kubernetes API failed to start'
  sleep 0.05
done
api_port=$(cat "$work/api-port")
health_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')

cat > "$work/kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: smoke
    cluster:
      server: http://127.0.0.1:$api_port
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

docker run -d --name "$container" --network host \
  -e ASPNETCORE_HTTP_PORTS="$health_port" \
  -e KUBECONFIG=/tmp/kubeconfig \
  -v "$work/kubeconfig:/tmp/kubeconfig:ro" \
  "$image" >/dev/null

for _ in $(seq 1 60); do
  if [ "$(docker inspect -f '{{.State.Running}}' "$container")" != true ]; then
    docker logs "$container" >&2 || true
    fail 'reflector exited before becoming healthy'
  fi
  live=$(curl -fsS --connect-timeout 1 --max-time 2 "http://127.0.0.1:$health_port/health/live" 2>/dev/null || true)
  ready=$(curl -fsS --connect-timeout 1 --max-time 2 "http://127.0.0.1:$health_port/health/ready" 2>/dev/null || true)
  [ "$live" = Healthy ] && [ "$ready" = Healthy ] && break
  sleep 0.5
done
[ "${live:-}" = Healthy ] || {
  docker logs "$container" >&2 || true
  fail 'liveness endpoint did not become healthy'
}
[ "${ready:-}" = Healthy ] || {
  docker logs "$container" >&2 || true
  fail 'readiness endpoint did not validate the Kubernetes API'
}
docker top "$container" | grep -q 'dotnet ES.Kubernetes.Reflector.dll' ||
  fail 'reflector .NET process is not running'

if docker run --name "$invalid_container" -e KUBECONFIG=/tmp/does-not-exist "$image" \
  >"$work/invalid.log" 2>&1
then
  fail 'missing Kubernetes configuration unexpectedly succeeded'
fi
grep -q 'kubeconfig file not found at /tmp/does-not-exist' "$work/invalid.log" || {
  cat "$work/invalid.log" >&2
  fail 'missing Kubernetes configuration did not fail clearly'
}

printf 'SMOKE PASS image=%s\n' "$image"
