#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
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

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] ||
  fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/external-secrets"]' ] ||
  fail 'unexpected entrypoint'

docker run --rm --network none "$image" --help > "$work/help"
grep -F -- '--metrics-addr' "$work/help" >/dev/null || fail 'metrics flag is missing'
grep -F -- '--live-addr' "$work/help" >/dev/null || fail 'health flag is missing'

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
                "namespaced": namespaced,
                "singularName": "",
                "verbs": ["create", "delete", "get", "list", "patch", "update", "watch"],
            }
            for name, kind, namespaced in resources
        ],
    }


CORE = [
    ("configmaps", "ConfigMap", True),
    ("events", "Event", True),
    ("namespaces", "Namespace", False),
    ("secrets", "Secret", True),
]
EXTERNAL = [
    ("clusterexternalsecrets", "ClusterExternalSecret", False),
    ("clusterpushsecrets", "ClusterPushSecret", False),
    ("clustersecretstores", "ClusterSecretStore", False),
    ("externalsecrets", "ExternalSecret", True),
    ("pushsecrets", "PushSecret", True),
    ("secretstores", "SecretStore", True),
]
GENERATORS = [("generatorstates", "GeneratorState", True)]


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
        if path == "/api":
            return self.send_json(200, {"apiVersion": "v1", "kind": "APIVersions", "serverAddressByClientCIDRs": [], "versions": ["v1"]})
        if path == "/api/v1":
            return self.send_json(200, resource_list("v1", CORE))
        if path == "/apis":
            groups = []
            external_versions = [
                {"groupVersion": "external-secrets.io/v1", "version": "v1"},
                {"groupVersion": "external-secrets.io/v1alpha1", "version": "v1alpha1"},
            ]
            groups.append({"name": "external-secrets.io", "preferredVersion": external_versions[0], "versions": external_versions})
            generator_version = {"groupVersion": "generators.external-secrets.io/v1alpha1", "version": "v1alpha1"}
            groups.append({"name": "generators.external-secrets.io", "preferredVersion": generator_version, "versions": [generator_version]})
            return self.send_json(200, {"apiVersion": "v1", "kind": "APIGroupList", "groups": groups})
        if path == "/apis/external-secrets.io/v1":
            return self.send_json(200, resource_list("external-secrets.io/v1", EXTERNAL))
        if path == "/apis/external-secrets.io/v1alpha1":
            return self.send_json(200, resource_list("external-secrets.io/v1alpha1", EXTERNAL))
        if path == "/apis/generators.external-secrets.io/v1alpha1":
            return self.send_json(200, resource_list("generators.external-secrets.io/v1alpha1", GENERATORS))
        if path == "/version":
            return self.send_json(200, {"gitVersion": "v1.34.0", "major": "1", "minor": "34"})
        return self.send_json(200, {"apiVersion": "v1", "items": [], "kind": "List", "metadata": {"resourceVersion": "1"}})

    def log_message(self, _format, *_args):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w", encoding="utf-8") as port_file:
    port_file.write(str(server.server_port))
server.serve_forever()
PY

python3 "$work/api.py" "$work/port" &
api_pid=$!
while [ ! -s "$work/port" ]; do
  kill -0 "$api_pid" 2>/dev/null || fail 'fake Kubernetes API failed to start'
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

container=$(docker run -d --network host \
  -e KUBECONFIG=/tmp/kubeconfig \
  -v "$work/kubeconfig:/tmp/kubeconfig:ro" \
  "$image" --metrics-addr=:18080 --live-addr=:18082)

deadline=$(( $(date +%s) + 30 ))
until curl -fsS http://127.0.0.1:18082/healthz >/dev/null 2>&1 &&
  curl -fsS http://127.0.0.1:18080/metrics > "$work/metrics" 2>/dev/null; do
  if [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)" != true ]; then
    docker logs "$container" >&2 || true
    fail 'External Secrets controller exited before becoming ready'
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    docker logs "$container" >&2 || true
    fail 'External Secrets endpoints did not become ready'
  fi
done
grep -q '^go_goroutines ' "$work/metrics" || fail 'metrics payload is invalid'

if docker run --rm --network none -e KUBECONFIG=/missing "$image" >/dev/null 2>&1; then
  fail 'missing kubeconfig unexpectedly succeeded'
fi

printf 'SMOKE PASS image=%s\n' "$image"
