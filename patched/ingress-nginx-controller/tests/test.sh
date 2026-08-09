#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE [FLAVOR]}
flavor=${2:-plain}
fixture=$(mktemp -d)
api_pid=
container=

cleanup() {
  [ -z "$container" ] || docker rm -f "$container" >/dev/null 2>&1 || true
  if [ -n "$api_pid" ]; then
    kill "$api_pid" >/dev/null 2>&1 || true
    wait "$api_pid" 2>/dev/null || true
  fi
  rm -rf "$fixture"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "error: $1" >&2
  exit 1
}

case $flavor in plain) ;; *) fail "unsupported flavor $flavor" ;; esac

[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/dumb-init","--"]' ] || \
  fail 'unexpected entrypoint'
docker run --rm --network none --entrypoint sh "$image" -c 'test "$(id -u)" = 101' || \
  fail 'image does not start as UID 101'
docker run --rm --network none --entrypoint sh "$image" -c 'test -x /nginx-ingress-controller' || \
  fail '/nginx-ingress-controller is not executable'
docker run --rm --network none --entrypoint sh "$image" -c 'test -x /wait-shutdown' || \
  fail '/wait-shutdown is not executable'

# Minimal fake Kubernetes API server: just enough discovery plus empty
# resource listings for the controller to complete startup and serve /healthz
# with leader election disabled.
cat > "$fixture/apiserver.py" <<'PY'
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def list_body(kind, api_version):
    return {"kind": kind, "apiVersion": api_version, "metadata": {"resourceVersion": "1"}, "items": []}


NAMESPACE = {
    "kind": "Namespace",
    "apiVersion": "v1",
    "metadata": {"name": "default", "uid": "fixture-ns", "resourceVersion": "1"},
    "status": {"phase": "Active"},
}
API_RESOURCES_V1 = {
    "kind": "APIResourceList",
    "groupVersion": "v1",
    "resources": [
        {"name": n, "namespaced": True, "kind": k, "verbs": ["get", "list", "watch"]}
        for n, k in [
            ("services", "Service"),
            ("endpoints", "Endpoints"),
            ("secrets", "Secret"),
            ("configmaps", "ConfigMap"),
            ("pods", "Pod"),
            ("namespaces", "Namespace"),
            ("events", "Event"),
        ]
    ],
}
API_GROUPS = {
    "kind": "APIGroupList",
    "groups": [
        {
            "name": "networking.k8s.io",
            "versions": [{"groupVersion": "networking.k8s.io/v1", "version": "v1"}],
            "preferredVersion": {"groupVersion": "networking.k8s.io/v1", "version": "v1"},
        },
        {
            "name": "discovery.k8s.io",
            "versions": [{"groupVersion": "discovery.k8s.io/v1", "version": "v1"}],
            "preferredVersion": {"groupVersion": "discovery.k8s.io/v1", "version": "v1"},
        },
        {
            "name": "coordination.k8s.io",
            "versions": [{"groupVersion": "coordination.k8s.io/v1", "version": "v1"}],
            "preferredVersion": {"groupVersion": "coordination.k8s.io/v1", "version": "v1"},
        },
    ],
}
NETWORKING_V1 = {
    "kind": "APIResourceList",
    "groupVersion": "networking.k8s.io/v1",
    "resources": [
        {"name": "ingresses", "namespaced": True, "kind": "Ingress", "verbs": ["get", "list", "watch"]},
        {"name": "ingressclasses", "namespaced": False, "kind": "IngressClass", "verbs": ["get", "list", "watch"]},
    ],
}
DISCOVERY_V1 = {
    "kind": "APIResourceList",
    "groupVersion": "discovery.k8s.io/v1",
    "resources": [
        {"name": "endpointslices", "namespaced": True, "kind": "EndpointSlice", "verbs": ["get", "list", "watch"]},
    ],
}
COORDINATION_V1 = {
    "kind": "APIResourceList",
    "groupVersion": "coordination.k8s.io/v1",
    "resources": [
        {"name": "leases", "namespaced": True, "kind": "Lease", "verbs": ["get", "list", "watch"]},
    ],
}
LIST_KINDS = {
    "ingressclasses": ("IngressClassList", "networking.k8s.io/v1"),
    "ingresses": ("IngressList", "networking.k8s.io/v1"),
    "endpointslices": ("EndpointSliceList", "discovery.k8s.io/v1"),
    "services": ("ServiceList", "v1"),
    "endpoints": ("EndpointsList", "v1"),
    "secrets": ("SecretList", "v1"),
    "configmaps": ("ConfigMapList", "v1"),
    "pods": ("PodList", "v1"),
    "namespaces": ("NamespaceList", "v1"),
    "events": ("EventList", "v1"),
    "leases": ("LeaseList", "coordination.k8s.io/v1"),
}


class Handler(BaseHTTPRequestHandler):
    def send_json(self, status, body):
        payload = (json.dumps(body) + "\n").encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        routes = {
            "/version": {"major": "1", "minor": "31", "gitVersion": "v1.31.0"},
            "/api": {"kind": "APIVersions", "versions": ["v1"], "serverAddressByClientCIDRs": []},
            "/apis": API_GROUPS,
            "/api/v1": API_RESOURCES_V1,
            "/api/v1/namespaces/default": NAMESPACE,
            "/apis/networking.k8s.io/v1": NETWORKING_V1,
            "/apis/discovery.k8s.io/v1": DISCOVERY_V1,
            "/apis/coordination.k8s.io/v1": COORDINATION_V1,
        }
        if path in routes:
            return self.send_json(200, routes[path])
        if "/pods/" in path:
            name = path.rsplit("/", 1)[-1]
            return self.send_json(200, {
                "kind": "Pod",
                "apiVersion": "v1",
                "metadata": {"name": name, "namespace": "default", "uid": "fixture-pod", "resourceVersion": "1", "labels": {}},
                "spec": {"containers": [{"name": "controller"}]},
                "status": {"phase": "Running", "podIP": "10.0.0.1", "hostIP": "10.0.0.1"},
            })
        for resource, (kind, api_version) in LIST_KINDS.items():
            if path.endswith("/" + resource):
                return self.send_json(200, list_body(kind, api_version))
        print(f"unexpected API path: {self.path}", file=sys.stderr, flush=True)
        self.send_error(404)

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
test -s "$fixture/api-port" || fail 'fixture API server did not start'
api_port=$(cat "$fixture/api-port")

container=verity-ingress-nginx-controller-$$
docker run -d --name "$container" --user 101 \
  --add-host host.docker.internal:host-gateway \
  -e POD_NAME="$container" -e POD_NAMESPACE=default \
  -p 127.0.0.1::80 -p 127.0.0.1::443 -p 127.0.0.1::10254 -p 127.0.0.1::8443 \
  "$image" /nginx-ingress-controller \
  --apiserver-host="http://host.docker.internal:$api_port" \
  --watch-namespace=default \
  --disable-leader-election \
  --health-check-path=/healthz \
  --healthz-port=10254 \
  --http-port=80 \
  --https-port=443 \
  --validating-webhook=:8443 >/dev/null

healthz_port=$(docker port "$container" 10254/tcp | awk -F: 'NR == 1 { print $2 }')
webhook_port=$(docker port "$container" 8443/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$healthz_port" ] && [ -n "$webhook_port" ] || fail 'expected ports were not published'

attempts=0
until curl --fail --silent --max-time 2 "http://127.0.0.1:$healthz_port/healthz" >/dev/null; do
  attempts=$((attempts + 1))
  if [ "$attempts" -ge 60 ]; then
    docker logs "$container" >&2 || :
    fail '/healthz did not become ready within 60 seconds'
  fi
  sleep 1
done

attempts=0
until python3 -c "import socket,sys; socket.create_connection(('127.0.0.1', int(sys.argv[1])), timeout=2).close()" "$webhook_port" 2>/dev/null; do
  attempts=$((attempts + 1))
  if [ "$attempts" -ge 30 ]; then
    docker logs "$container" >&2 || :
    fail 'validating webhook listener on 8443 did not come up'
  fi
  sleep 1
done

docker exec "$container" /wait-shutdown || fail '/wait-shutdown returned a nonzero status'
attempts=0
while [ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ]; do
  attempts=$((attempts + 1))
  if [ "$attempts" -ge 30 ]; then
    docker logs "$container" >&2 || :
    fail 'controller did not exit after /wait-shutdown drained nginx'
  fi
  sleep 1
done
[ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ] || \
  fail 'controller exited with a nonzero status after graceful shutdown'
docker rm -f "$container" >/dev/null 2>&1 || true
container=

if docker run --rm --network none --user 101 "$image" /nginx-ingress-controller --not-a-real-flag >/dev/null 2>&1; then
  fail 'invalid flag unexpectedly succeeded'
fi

printf 'SMOKE PASS image=%s\n' "$image"
