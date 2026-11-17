#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-prometheus-adapter-test-$$"
fixture=$(mktemp -d)
fixture_pid=

fail() {
  printf '%s: %s\n' "$image" "$1" >&2
  docker logs "$container" >&2 2>/dev/null || true
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  [ -z "$fixture_pid" ] || kill "$fixture_pid" >/dev/null 2>&1 || true
  rm -rf "$fixture"
}
trap cleanup EXIT INT TERM

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] ||
  fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/prometheus-adapter"]' ] || fail 'unexpected OCI entrypoint'
[ "$(docker image inspect -f '{{json .Config.Cmd}}' "$image")" = \
  '["--secure-port=6443","--cert-dir=/tmp"]' ] || fail 'unexpected OCI cmd'

# The adapter only needs API discovery and SubjectAccessReview from the core
# API server, plus the Prometheus series and query endpoints. One stdlib HTTP
# fixture plays both roles so the smoke test stays self-contained: a real
# kube-apiserver would need a second published image, etcd, and PKI setup that
# the per-image CI smoke job does not provide, without exercising more adapter
# behavior than these protocol responses do.
cat > "$fixture/fixture.py" <<'PY'
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PODS_RESOURCE = {"name": "pods", "singularName": "pod", "namespaced": True, "kind": "Pod", "verbs": ["get", "list", "watch"]}
NS_RESOURCE = {"name": "namespaces", "singularName": "namespace", "namespaced": False, "kind": "Namespace", "verbs": ["get", "list", "watch"]}
SERIES = [
    {"__name__": "smoke_requests_total", "namespace": "default", "pod": "fixture-pod"},
]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def reply(self, body, status=200):
        payload = (json.dumps(body) + "\n").encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def route(self, method):
        request = urlparse(self.path)
        path = request.path
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        # Fake Prometheus HTTP API.
        if path in ("/api/v1/query", "/api/v1/query_range"):
            query = parse_qs(request.query).get("query", [""])[0]
            print(f"query: {query}", file=sys.stderr, flush=True)
            result = []
            if 'pod="fixture-pod"' in query:
                result = [{"metric": {"namespace": "default", "pod": "fixture-pod"}, "value": [1700000000, "42"]}]
            return self.reply({"status": "success", "data": {"resultType": "vector", "result": result}})
        if path == "/api/v1/series":
            return self.reply({"status": "success", "data": SERIES})
        # Fake Kubernetes API server.
        if path == "/version":
            return self.reply({"major": "1", "minor": "35", "gitVersion": "v1.35.0"})
        if path == "/api":
            return self.reply({"kind": "APIVersions", "apiVersion": "v1", "versions": ["v1"]})
        if path == "/apis":
            return self.reply({"kind": "APIGroupList", "apiVersion": "v1", "groups": []})
        if path == "/api/v1":
            return self.reply({"kind": "APIResourceList", "apiVersion": "v1", "groupVersion": "v1", "resources": [PODS_RESOURCE, NS_RESOURCE]})
        if method == "POST" and path == "/apis/authorization.k8s.io/v1/subjectaccessreviews":
            review = json.loads(raw or b"{}")
            review["status"] = {"allowed": True, "reason": "smoke fixture"}
            return self.reply(review, 201)
        print(f"unexpected path: {method} {self.path}", file=sys.stderr, flush=True)
        self.reply({"kind": "Status", "apiVersion": "v1", "status": "Failure", "reason": "NotFound", "code": 404}, 404)

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def log_message(self, *_):
        pass


server = ThreadingHTTPServer(("0.0.0.0", 0), Handler)
with open(sys.argv[1], "w", encoding="utf-8") as port_file:
    port_file.write(str(server.server_port))
server.serve_forever()
PY
python3 "$fixture/fixture.py" "$fixture/port" 2>"$fixture/fixture.log" &
fixture_pid=$!
for _ in $(seq 1 100); do
  [ -s "$fixture/port" ] && break
  sleep 0.1
done
[ -s "$fixture/port" ] || fail 'fixture server did not start'
fixture_port=$(cat "$fixture/port")

cat > "$fixture/kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: fixture
    cluster:
      server: http://host.docker.internal:${fixture_port}
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

cat > "$fixture/config.yaml" <<'EOF'
rules:
  - seriesQuery: 'smoke_requests_total{namespace!="",pod!=""}'
    resources:
      overrides:
        namespace: {resource: namespace}
        pod: {resource: pod}
    name:
      matches: "^(.*)_total$"
      as: "${1}_per_second"
    metricsQuery: 'sum(rate(<<.Series>>{<<.LabelMatchers>>}[2m])) by (<<.GroupBy>>)'
EOF
printf 'rules: [\n' > "$fixture/invalid.yaml"
chmod 644 "$fixture/kubeconfig" "$fixture/config.yaml" "$fixture/invalid.yaml"

run_adapter() {
  config=$1
  shift
  docker run "$@" --read-only --user 65532 \
    --add-host host.docker.internal:host-gateway \
    --tmpfs /tmp:uid=65532,gid=65532,mode=1777 \
    -v "$fixture/kubeconfig:/etc/adapter/kubeconfig:ro" \
    -v "$fixture/$config:/etc/adapter/config.yaml:ro" \
    "$image" \
    --secure-port=6443 \
    --cert-dir=/tmp \
    --lister-kubeconfig=/etc/adapter/kubeconfig \
    --authentication-kubeconfig=/etc/adapter/kubeconfig \
    --authorization-kubeconfig=/etc/adapter/kubeconfig \
    --authentication-skip-lookup \
    --prometheus-url="http://host.docker.internal:${fixture_port}/" \
    --config=/etc/adapter/config.yaml \
    --metrics-relist-interval=5s
}

run_adapter config.yaml --name "$container" -d -p 127.0.0.1::6443 >/dev/null
port=$(docker port "$container" 6443/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || fail 'secure port was not published'
base="https://127.0.0.1:${port}"

i=0
until [ "$(curl -ks --max-time 5 "$base/healthz" 2>/dev/null || true)" = ok ]; do
  [ "$(docker inspect -f '{{.State.Running}}' "$container")" = true ] ||
    fail 'adapter exited before /healthz became ready'
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail '/healthz never returned ok'
  sleep 1
done

# Discovery lists metrics derived from the fake Prometheus series via the rule.
i=0
until curl -ks --fail --max-time 5 "$base/apis/custom.metrics.k8s.io/v1beta2" \
  >"$fixture/discovery.json" 2>/dev/null &&
  grep -Fq '"pods/smoke_requests_per_second"' "$fixture/discovery.json"; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || { cat "$fixture/discovery.json" >&2 || true; fail 'custom metrics discovery missing pods/smoke_requests_per_second'; }
  sleep 1
done
grep -Fq '"groupVersion": "custom.metrics.k8s.io/v1beta2"' "$fixture/discovery.json" ||
  fail 'discovery returned the wrong group version'
grep -Fq '"namespaces/smoke_requests_per_second"' "$fixture/discovery.json" ||
  fail 'custom metrics discovery missing namespaces/smoke_requests_per_second'

# A metric read is translated into a PromQL query and the value is returned.
value=$(curl -ks --fail --max-time 5 \
  "$base/apis/custom.metrics.k8s.io/v1beta2/namespaces/default/pods/fixture-pod/smoke_requests_per_second") ||
  fail 'custom metric read failed'
printf '%s\n' "$value" | grep -Fq '"kind": "MetricValueList"' || fail 'metric read returned wrong kind'
printf '%s\n' "$value" | grep -Fq '"name": "fixture-pod"' || fail 'metric read missing described pod'
printf '%s\n' "$value" | grep -Fq '"value": "42"' || fail 'metric read returned wrong value'
grep -Fq 'smoke_requests_total{namespace="default",pod="fixture-pod"}' "$fixture/fixture.log" ||
  fail 'adapter did not issue the expected PromQL query'

# Negative: an unknown metric is a NotFound API status, not a value.
code=$(curl -ks -o "$fixture/missing.json" -w '%{http_code}' --max-time 5 \
  "$base/apis/custom.metrics.k8s.io/v1beta2/namespaces/default/pods/fixture-pod/no_such_metric")
[ "$code" = 404 ] || fail "unknown metric returned HTTP $code"
grep -Fq '"reason": "NotFound"' "$fixture/missing.json" || fail 'unknown metric missing NotFound status'

# Negative: an unparsable discovery config must stop the adapter.
if output=$(run_adapter invalid.yaml --rm 2>&1); then
  fail 'invalid config unexpectedly succeeded'
fi
printf '%s\n' "$output" | grep -Fq 'unable to parse metrics discovery config' ||
  fail 'invalid config error missing'

printf 'SMOKE PASS %s\n' "$image"
