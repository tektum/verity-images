#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
recipe="$(dirname "$0")/../melange.yaml"
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' "$recipe")
expected_commit=$(sed -n 's/^[[:space:]]*source-commit: \([0-9a-f]\{40\}\)$/\1/p' "$recipe")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
[ -n "$expected_commit" ] || { printf 'source commit not found\n' >&2; exit 1; }
work=$(mktemp -d)
api_pid=
container=
secure_port=16443
metrics_port=18080

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
  for log in "$work"/*.log; do
    [ -f "$log" ] && cat "$log" >&2
  done
  if [ -n "$container" ]; then
    docker logs "$container" >&2 2>&1 || true
  fi
  exit 1
}

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] ||
  fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = \
  '["/keda-adapter","--secure-port=6443","--zap-log-level=info","--zap-encoder=console"]' ] ||
  fail 'unexpected entrypoint'

docker run --rm --network none "$image" --help >"$work/help.log" 2>&1 ||
  fail 'keda-adapter --help failed'
for flag in --secure-port --cert-dir --lister-kubeconfig --metrics-service-address --port; do
  grep -F -- "$flag " "$work/help.log" >/dev/null || fail "help output lacks $flag"
done
rm -f "$work/help.log"

# Negative: an unknown flag is rejected with a usage error.
status=0
docker run --rm --network none "$image" --no-such-flag >"$work/flag.log" 2>&1 || status=$?
[ "$status" -eq 2 ] || fail "unknown flag exited with $status, expected 2"
grep -F 'unknown flag: --no-such-flag' "$work/flag.log" >/dev/null ||
  fail 'unknown flag error is not reported'
rm -f "$work/flag.log"

# Negative: without in-cluster environment or kubeconfig the adapter stops
# with the documented configuration error instead of serving. Upstream logs
# the error and returns from main, so the exit status is not asserted.
timeout 120 docker run --rm --network none "$image" >"$work/noconfig.log" 2>&1 || true
grep -F 'unable to run external metrics adapter' "$work/noconfig.log" >/dev/null ||
  fail 'adapter did not stop on missing configuration'
grep -F 'unable to load in-cluster configuration' "$work/noconfig.log" >/dev/null ||
  fail 'missing configuration error is not reported'
rm -f "$work/noconfig.log"

# Positive: against a minimal fake API server the adapter loads its
# kubeconfig and the gRPC client certificates from its certificate directory,
# reports its build identity, and serves its metrics and secure health
# endpoints.
cat >"$work/api.py" <<'PY'
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


RESOURCES = {
    "v1": [
        ("configmaps", "ConfigMap", True),
        ("namespaces", "Namespace", False),
        ("pods", "Pod", True),
        ("secrets", "Secret", True),
        ("serviceaccounts", "ServiceAccount", True),
    ],
    "apps/v1": [
        ("deployments", "Deployment", True),
        ("statefulsets", "StatefulSet", True),
    ],
    "autoscaling/v2": [("horizontalpodautoscalers", "HorizontalPodAutoscaler", True)],
    "keda.sh/v1alpha1": [
        ("clustertriggerauthentications", "ClusterTriggerAuthentication", False),
        ("scaledjobs", "ScaledJob", True),
        ("scaledobjects", "ScaledObject", True),
        ("triggerauthentications", "TriggerAuthentication", True),
    ],
    "eventing.keda.sh/v1alpha1": [
        ("cloudeventsources", "CloudEventSource", True),
        ("clustercloudeventsources", "ClusterCloudEventSource", False),
    ],
}


def resource_list(group_version):
    return {
        "apiVersion": "v1",
        "kind": "APIResourceList",
        "groupVersion": group_version,
        "resources": [
            {
                "kind": kind,
                "name": name,
                "namespaced": namespaced,
                "singularName": "",
                "verbs": ["create", "delete", "get", "list", "patch", "update", "watch"],
            }
            for name, kind, namespaced in RESOURCES[group_version]
        ],
    }


def group_list():
    groups = []
    for group_version in RESOURCES:
        if group_version == "v1":
            continue
        group, version = group_version.split("/")
        entry = {"groupVersion": group_version, "version": version}
        groups.append({"name": group, "preferredVersion": entry, "versions": [entry]})
    return {"apiVersion": "v1", "kind": "APIGroupList", "groups": groups}


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
        path, _, query = self.path.partition("?")
        if path == "/version":
            return self.send_json(200, {"major": "1", "minor": "34", "gitVersion": "v1.34.0"})
        if path == "/api":
            return self.send_json(200, {"apiVersion": "v1", "kind": "APIVersions", "versions": ["v1"],
                                        "serverAddressByClientCIDRs": []})
        if path == "/api/v1":
            return self.send_json(200, resource_list("v1"))
        if path == "/apis":
            return self.send_json(200, group_list())
        if path.startswith("/apis/") and path[len("/apis/"):] in RESOURCES:
            return self.send_json(200, resource_list(path[len("/apis/"):]))
        if "watch=true" in query:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            time.sleep(300)
            return
        return self.send_json(200, {"apiVersion": "v1", "kind": "List", "items": [], "metadata": {"resourceVersion": "1"}})

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
attempts=0
until [ -s "$work/port" ]; do
  kill -0 "$api_pid" 2>/dev/null || fail 'fake Kubernetes API failed to start'
  attempts=$((attempts + 1))
  [ "$attempts" -lt 100 ] || fail 'fake Kubernetes API did not report its port'
  sleep 0.1
done
port=$(cat "$work/port")

cat >"$work/kubeconfig" <<EOF
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

# The adapter reads ca.crt, tls.crt and tls.key from --cert-dir for its gRPC
# client and may write its serving pair there, so the directory is writable.
mkdir "$work/certs"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=127.0.0.1 \
  -keyout "$work/certs/tls.key" -out "$work/certs/tls.crt" >/dev/null 2>&1 ||
  fail 'could not create the test certificate'
cp "$work/certs/tls.crt" "$work/certs/ca.crt"
chmod 0777 "$work/certs"
chmod 0644 "$work/certs/tls.key" "$work/certs/tls.crt" "$work/certs/ca.crt"

container=$(docker run -d --network host --read-only \
  -v "$work/certs:/certs" \
  -e WATCH_NAMESPACE= -e KUBECONFIG=/kubeconfig \
  -v "$work/kubeconfig:/kubeconfig:ro" \
  "$image" --secure-port="$secure_port" --port="$metrics_port" --cert-dir=/certs \
  --lister-kubeconfig=/kubeconfig --authentication-kubeconfig=/kubeconfig \
  --authorization-kubeconfig=/kubeconfig --authentication-skip-lookup \
  --metrics-service-address=127.0.0.1:1)

attempts=0
until curl -ksS --max-time 2 "https://127.0.0.1:$secure_port/healthz" >"$work/healthz" 2>/dev/null &&
  [ "$(cat "$work/healthz")" = ok ]; do
  [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)" = true ] ||
    fail 'adapter exited before becoming healthy'
  attempts=$((attempts + 1))
  [ "$attempts" -lt 120 ] || fail 'adapter secure healthz did not report ok'
  sleep 1
done

curl -fsS --max-time 5 "http://127.0.0.1:$metrics_port/metrics" >"$work/metrics" ||
  fail 'metrics endpoint is not reachable'
grep -q '^go_goroutines ' "$work/metrics" || fail 'metrics payload is invalid'

docker logs "$container" >"$work/run.log" 2>&1
grep -F "KEDA Version: $expected_version" "$work/run.log" >/dev/null ||
  fail "adapter does not report version $expected_version"
grep -F "Git Commit: $expected_commit" "$work/run.log" >/dev/null ||
  fail "adapter does not report commit $expected_commit"
rm -f "$work/run.log"

printf 'SMOKE PASS image=%s\n' "$image"
