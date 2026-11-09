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
webhook_port=19443
probe_port=18081
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
  '["/keda-admission-webhooks","--zap-log-level=info","--zap-encoder=console"]' ] ||
  fail 'unexpected entrypoint'

docker run --rm --network none "$image" --help >"$work/help.log" 2>&1 ||
  fail 'keda-admission-webhooks --help failed'
for flag in --cert-dir --port --health-probe-bind-address --metrics-bind-address --zap-log-level; do
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

# Negative: without in-cluster environment or kubeconfig the webhooks exit
# with the documented configuration error instead of hanging.
status=0
docker run --rm --network none "$image" >"$work/noconfig.log" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail 'webhooks without kubeconfig unexpectedly succeeded'
grep -F 'unable to get kubeconfig' "$work/noconfig.log" >/dev/null ||
  fail 'missing kubeconfig error is not reported'
rm -f "$work/noconfig.log"

# Positive: against a minimal fake API server the webhooks load their
# kubeconfig, report their build identity, and serve health and TLS webhook
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

mkdir "$work/certs"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=127.0.0.1 \
  -keyout "$work/certs/tls.key" -out "$work/certs/tls.crt" >/dev/null 2>&1 ||
  fail 'could not create the test webhook certificate'
chmod 0755 "$work/certs"
chmod 0644 "$work/certs/tls.key" "$work/certs/tls.crt"

container=$(docker run -d --network host --read-only \
  -e KUBECONFIG=/kubeconfig \
  -v "$work/kubeconfig:/kubeconfig:ro" -v "$work/certs:/certs:ro" \
  "$image" --port="$webhook_port" \
  --health-probe-bind-address="127.0.0.1:$probe_port" \
  --metrics-bind-address="127.0.0.1:$metrics_port")

attempts=0
until curl -fsS --max-time 2 "http://127.0.0.1:$probe_port/readyz" >"$work/readyz" 2>/dev/null; do
  [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)" = true ] ||
    fail 'webhooks exited before becoming ready'
  attempts=$((attempts + 1))
  [ "$attempts" -lt 120 ] || fail 'webhooks did not become ready'
  sleep 1
done
[ "$(cat "$work/readyz")" = ok ] || fail 'readyz body is not ok'
[ "$(curl -fsS --max-time 5 "http://127.0.0.1:$probe_port/healthz")" = ok ] ||
  fail 'healthz is not ok'

docker logs "$container" >"$work/run.log" 2>&1
grep -F "KEDA Version: $expected_version" "$work/run.log" >/dev/null ||
  fail "webhooks do not report version $expected_version"
grep -F "Git Commit: $expected_commit" "$work/run.log" >/dev/null ||
  fail "webhooks do not report commit $expected_commit"
grep -F 'Registering webhook' "$work/run.log" >/dev/null ||
  fail 'webhooks did not register validation handlers'
rm -f "$work/run.log"

# Negative: the TLS webhook endpoint rejects an empty admission review.
attempts=0
until curl -ksS --max-time 5 -X POST -H 'Content-Type: application/json' \
  "https://127.0.0.1:$webhook_port/validate-keda-sh-v1alpha1-scaledobject" >"$work/review" 2>/dev/null; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || fail 'webhook TLS endpoint is not reachable'
  sleep 1
done
grep -F '"allowed":false' "$work/review" >/dev/null || {
  cat "$work/review" >&2
  fail 'empty admission review was not rejected'
}

printf 'SMOKE PASS image=%s\n' "$image"
