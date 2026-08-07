#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-kube-state-metrics-test-$$"
fixture=$(mktemp -d)
api_pid=

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  [ -z "$api_pid" ] || kill "$api_pid" >/dev/null 2>&1 || true
  rm -rf "$fixture"
}
trap cleanup EXIT INT TERM

test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/kube-state-metrics"]'
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532

cat > "$fixture/apiserver.py" <<'PY'
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        request = urlparse(self.path)
        if request.path == "/version":
            body = {"major": "1", "minor": "35", "gitVersion": "v1.35.0"}
        elif request.path == "/api":
            body = {"kind": "APIVersions", "apiVersion": "v1", "versions": ["v1"]}
        elif request.path == "/apis":
            body = {"kind": "APIGroupList", "apiVersion": "v1", "groups": []}
        elif request.path == "/api/v1":
            body = {"kind": "APIResourceList", "apiVersion": "v1", "groupVersion": "v1", "resources": [{"name": "pods", "singularName": "", "namespaced": True, "kind": "Pod", "verbs": ["get", "list", "watch"]}]}
        elif request.path == "/api/v1/pods" and parse_qs(request.query).get("watch") == ["true"]:
            body = {"type": "BOOKMARK", "object": {"kind": "Pod", "apiVersion": "v1", "metadata": {"resourceVersion": "1"}}}
        elif request.path == "/api/v1/pods":
            body = {"kind": "PodList", "apiVersion": "v1", "metadata": {"resourceVersion": "1"}, "items": [{"kind": "Pod", "apiVersion": "v1", "metadata": {"name": "fixture", "namespace": "default", "uid": "fixture-uid", "resourceVersion": "1"}, "spec": {"nodeName": "fixture-node", "containers": []}, "status": {"phase": "Running"}}]}
        else:
            self.send_error(404)
            return
        payload = (json.dumps(body) + "\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_):
        pass


server = ThreadingHTTPServer(("0.0.0.0", 0), Handler)
with open(sys.argv[1], "w", encoding="utf-8") as port_file:
    port_file.write(str(server.server_port))
server.serve_forever()
PY
python3 "$fixture/apiserver.py" "$fixture/api-port" &
api_pid=$!
for _ in $(seq 1 100); do
  [ -s "$fixture/api-port" ] && break
  sleep 0.1
done
test -s "$fixture/api-port"
api_port=$(cat "$fixture/api-port")

cat > "$fixture/kubeconfig" <<'EOF'
apiVersion: v1
kind: Config
clusters:
  - name: fixture
    cluster:
      server: API_SERVER
contexts:
  - name: fixture
    context:
      cluster: fixture
      user: fixture
current-context: fixture
users:
  - name: fixture
    user: {}
EOF
sed -i "s/API_SERVER/http:\/\/host.docker.internal:$api_port/" "$fixture/kubeconfig"
chmod 644 "$fixture/kubeconfig"

docker run --name "$container" -d --read-only --user 65532 \
  --add-host host.docker.internal:host-gateway \
  --tmpfs /tmp:uid=65532,gid=65532 \
  -v "$fixture/kubeconfig:/tmp/kubeconfig:ro" \
  -p 127.0.0.1::8080 -p 127.0.0.1::8081 "$image" \
  --kubeconfig=/tmp/kubeconfig --resources=pods --port=8080 --telemetry-port=8081 >/dev/null
port=$(docker port "$container" 8080/tcp | awk -F: 'NR == 1 { print $2 }')
telemetry_port=$(docker port "$container" 8081/tcp | awk -F: 'NR == 1 { print $2 }')
test -n "$port" && test -n "$telemetry_port" || { docker logs "$container" >&2 || true; exit 1; }

metrics_ready=
for _ in $(seq 1 100); do
  if curl --fail --silent --connect-timeout 1 --max-time 5 \
      "http://127.0.0.1:$port/metrics" > "$fixture/metrics" &&
    grep -q '^kube_pod_info{.*pod="fixture"' "$fixture/metrics"; then
    metrics_ready=1
    break
  fi
  sleep 0.1
done
test -n "$metrics_ready" || {
  docker logs "$container" >&2
  printf 'metrics endpoint did not expose fixture pod\n' >&2
  exit 1
}

telemetry_ready=
for _ in $(seq 1 100); do
  if curl --fail --silent --connect-timeout 1 --max-time 5 \
      "http://127.0.0.1:$telemetry_port/metrics" > "$fixture/telemetry" &&
    grep -q '^kube_state_metrics_build_info{' "$fixture/telemetry"; then
    telemetry_ready=1
    break
  fi
  sleep 0.1
done
test -n "$telemetry_ready" || {
  docker logs "$container" >&2
  printf 'telemetry endpoint did not expose build info\n' >&2
  exit 1
}

printf 'apiVersion: [' > "$fixture/invalid-kubeconfig"
chmod 644 "$fixture/invalid-kubeconfig"
if docker run --rm --user 65532 \
  -v "$fixture/invalid-kubeconfig:/tmp/kubeconfig:ro" \
  "$image" --kubeconfig=/tmp/kubeconfig >/dev/null 2>&1; then
  printf 'invalid kubeconfig unexpectedly succeeded\n' >&2
  exit 1
fi

printf 'SMOKE PASS image=%s\n' "$image"
