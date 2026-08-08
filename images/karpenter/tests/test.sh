#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-karpenter-test-$$"
help_container="${container}-help"
missing_container="${container}-missing"
fixture=$(mktemp -d)
api_pid=

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker rm -f "$help_container" >/dev/null 2>&1 || true
  docker rm -f "$missing_container" >/dev/null 2>&1 || true
  [ -z "$api_pid" ] || kill "$api_pid" >/dev/null 2>&1 || true
  rm -rf "$fixture"
}
trap cleanup EXIT INT TERM

test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/controller"]'
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532

# Happy path: --help succeeds before any cluster config is read.
docker run --name "$help_container" --user 65532 "$image" --help \
  >"$fixture/help.log" 2>&1
grep -Eqi 'metrics-port|health-probe-port|kube-client-qps' "$fixture/help.log"

# Happy path: read-only-root startup reaches the liveness endpoint. Startup
# unconditionally resolves Kubernetes REST mappings while building the
# manager's indexers, and hydrates its EC2 instance type cache before
# starting any controllers, so the fixture answers both Kubernetes discovery
# and the specific EC2 calls the AWS provider makes at startup.
cat > "$fixture/apiserver.py" <<'PY'
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

# Group/version -> resources. The controller-runtime manager resolves REST
# mappings for these kinds while constructing indexers, before any real
# reconciliation happens, so discovery must answer them even without a real
# cluster behind it.
GROUP_VERSIONS = {
    "v1": [
        {"name": "pods", "singularName": "pod", "namespaced": True, "kind": "Pod",
         "verbs": ["get", "list", "watch"]},
        {"name": "nodes", "singularName": "node", "namespaced": False, "kind": "Node",
         "verbs": ["get", "list", "watch"]},
    ],
    "coordination.k8s.io/v1": [
        {"name": "leases", "singularName": "lease", "namespaced": True, "kind": "Lease",
         "verbs": ["get", "list", "watch", "create", "update", "patch", "delete"]},
    ],
    "storage.k8s.io/v1": [
        {"name": "volumeattachments", "singularName": "volumeattachment", "namespaced": False,
         "kind": "VolumeAttachment", "verbs": ["get", "list", "watch"]},
    ],
}
GROUPS = [
    {
        "name": group,
        "versions": [{"groupVersion": f"{group}/v1", "version": "v1"}],
        "preferredVersion": {"groupVersion": f"{group}/v1", "version": "v1"},
    }
    for group in ("coordination.k8s.io", "storage.k8s.io")
]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/version":
            body = {"major": "1", "minor": "31", "gitVersion": "v1.31.0"}
        elif path == "/api":
            body = {"kind": "APIVersions", "versions": ["v1"], "serverAddressByClientCIDRs": []}
        elif path == "/api/v1":
            body = {"kind": "APIResourceList", "groupVersion": "v1", "resources": GROUP_VERSIONS["v1"]}
        elif path == "/apis":
            body = {"kind": "APIGroupList", "groups": GROUPS}
        elif path.startswith("/apis/") and path.count("/") == 3:
            group_version = path[len("/apis/"):]
            if group_version in GROUP_VERSIONS:
                body = {"kind": "APIResourceList", "groupVersion": group_version,
                        "resources": GROUP_VERSIONS[group_version]}
            else:
                print(f"unexpected API path: {path}", file=sys.stderr, flush=True)
                self.send_error(404)
                return
        else:
            print(f"unexpected API path: {path}", file=sys.stderr, flush=True)
            self.send_error(404)
            return
        payload = (json.dumps(body) + "\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        # EC2 uses a query-style protocol: Action and DryRun arrive as
        # form-encoded POST fields, not the URL path.
        length = int(self.headers.get("Content-Length", "0"))
        form = parse_qs(self.rfile.read(length).decode())
        action = form.get("Action", [""])[0]
        dry_run = form.get("DryRun", ["false"])[0] == "true"
        if dry_run:
            # The startup EC2 connectivity check issues a DryRun request and
            # treats the DryRunOperation error as confirmation that the call
            # would have succeeded, without needing real EC2 access.
            status, body = 412, (
                "<Response><Errors><Error><Code>DryRunOperation</Code>"
                "<Message>Request would have succeeded, but DryRun flag is set.</Message>"
                "</Error></Errors><RequestID>smoke-test</RequestID></Response>"
            )
        elif action == "DescribeInstanceTypes":
            # Karpenter hydrates its instance type cache at startup before
            # starting any controllers; an empty catalog is enough to clear
            # that gate without needing real EC2 instance-type data.
            status, body = 200, (
                '<DescribeInstanceTypesResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">'
                "<requestId>smoke-test</requestId><instanceTypeSet/></DescribeInstanceTypesResponse>"
            )
        elif action == "DescribeInstanceTypeOfferings":
            status, body = 200, (
                '<DescribeInstanceTypeOfferingsResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">'
                "<requestId>smoke-test</requestId><instanceTypeOfferingSet/>"
                "</DescribeInstanceTypeOfferingsResponse>"
            )
        else:
            print(f"unexpected EC2 action: {action}", file=sys.stderr, flush=True)
            status, body = 200, (
                '<Response xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">'
                "<requestId>smoke-test</requestId></Response>"
            )
        payload = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/xml")
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

cat > "$fixture/kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: smoke
    cluster:
      server: http://host.docker.internal:$api_port
contexts:
  - name: smoke
    context:
      cluster: smoke
      user: smoke
current-context: smoke
users:
  - name: smoke
    user: {}
EOF
chmod 644 "$fixture/kubeconfig"

docker run --name "$container" -d --read-only --user 65532 \
  --add-host host.docker.internal:host-gateway \
  --tmpfs /tmp:uid=65532,gid=65532 \
  -v "$fixture/kubeconfig:/tmp/kubeconfig:ro" \
  -e KUBECONFIG=/tmp/kubeconfig \
  -e CLUSTER_NAME=smoke-cluster \
  -e CLUSTER_ENDPOINT=https://smoke-cluster.example.invalid \
  -e AWS_REGION=us-east-1 \
  -e AWS_ACCESS_KEY_ID=AKIASMOKETESTFIXTURE \
  -e AWS_SECRET_ACCESS_KEY=smoke-test-fixture-secret \
  -e AWS_ENDPOINT_URL_EC2="http://host.docker.internal:$api_port" \
  -e DISABLE_LEADER_ELECTION=true \
  -p 127.0.0.1::8081 "$image" >/dev/null
health_port=$(docker port "$container" 8081/tcp | awk -F: 'NR == 1 { print $2 }')
test -n "$health_port" || { docker logs "$container" >&2 || true; exit 1; }

i=0
until curl --fail --silent --output /dev/null --connect-timeout 1 --max-time 5 \
  "http://127.0.0.1:$health_port/healthz"; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || { docker logs "$container" >&2 || true; exit 1; }
  sleep 1
done
test "$(docker inspect -f '{{.State.Running}}' "$container")" = true

# Failure path: no cluster-name, no kubeconfig, no in-cluster service account,
# and no KUBERNETES_SERVICE_HOST/PORT means the controller cannot resolve
# cluster config and must exit nonzero.
if docker run --name "$missing_container" --user 65532 "$image" \
  >"$fixture/missing-config.log" 2>&1; then
  printf 'missing cluster config unexpectedly succeeded\n' >&2
  cat "$fixture/missing-config.log" >&2
  exit 1
fi
grep -Eq 'missing field, cluster-name|unable to get kubeconfig' "$fixture/missing-config.log"

printf 'SMOKE PASS image=%s\n' "$image"
