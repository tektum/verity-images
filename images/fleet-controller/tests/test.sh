#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container=verity-fleet-controller-$$
work=$(mktemp -d)
stub_pid=

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  if [ -n "$stub_pid" ]; then
    kill "$stub_pid" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT INT TERM
chmod 755 "$work"

fail() {
  printf '%s\n' "$1" >&2
  if [ -f "$work/controller.log" ]; then
    tail -n 20 "$work/controller.log" >&2
  fi
  exit 1
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 1000 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/fleetcontroller"]' || fail 'unexpected entrypoint'
# The Fleet chart runs fleetcontroller by name, and GitRepo jobs run the fleet
# CLI from this image with command ["fleet"].
for binary in fleetcontroller fleet; do
  docker run --rm --network none --entrypoint "$binary" "$image" --version >"$work/version" 2>&1 ||
    fail "$binary is not on PATH"
  grep -E ' version v[0-9]+\.[0-9]+\.[0-9]+ \([0-9a-f]{40}\)$' "$work/version" >/dev/null ||
    fail "$binary version output is missing"
done
docker run --rm --network none --read-only "$image" --help >"$work/help" 2>&1 || fail 'fleetcontroller --help failed'
for flag in --namespace --kubeconfig --leader-elect --shard-id --disable-metrics; do
  grep -F -- "$flag" "$work/help" >/dev/null || fail "fleetcontroller --help does not list $flag"
done

# The fleet CLI renders a Bundle from a local directory without a cluster. Like
# the chart, which mounts an emptyDir there, it needs a writable /tmp.
mkdir -p "$work/repo/app"
cat >"$work/repo/app/configmap.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: verity-smoke
data:
  greeting: hello-from-verity
EOF
chmod -R a+rX "$work/repo"
docker run --rm --network none --read-only --tmpfs /tmp --entrypoint fleet -v "$work/repo:/repo:ro" -w /repo "$image" \
  apply -n fleet-local -o - smoke app >"$work/bundle.yaml" 2>"$work/bundle.err" ||
  { cat "$work/bundle.err" >&2; fail 'fleet apply -o - failed'; }
grep -Fx 'kind: Bundle' "$work/bundle.yaml" >/dev/null || fail 'fleet apply did not render a Bundle'
grep -F 'hello-from-verity' "$work/bundle.yaml" >/dev/null || fail 'rendered Bundle is missing the manifest'
# Negative: a missing bundle directory must fail.
if docker run --rm --network none --read-only --tmpfs /tmp --entrypoint fleet -v "$work/repo:/repo:ro" -w /repo "$image" \
  apply -n fleet-local -o - smoke does-not-exist >/dev/null 2>&1; then
  fail 'fleet apply accepted a missing directory'
fi

# Negative: an unknown flag must exit non-zero.
if docker run --rm --network none --read-only "$image" --no-such-flag >/dev/null 2>&1; then
  fail 'unknown flag unexpectedly succeeded'
fi

# Negative: without a kubeconfig or in-cluster environment it must exit, not hang.
status=0
timeout 60 docker run --rm --network none --read-only \
  -e CATTLE_ELECTION_LEASE_DURATION=20s -e CATTLE_ELECTION_RENEW_DEADLINE=10s \
  -e CATTLE_ELECTION_RETRY_PERIOD=2s "$image" >"$work/noconfig" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail 'controller started without any cluster configuration'
[ "$status" -ne 124 ] || fail 'controller hung without any cluster configuration instead of exiting'
grep -F 'unable to load in-cluster configuration' "$work/noconfig" >/dev/null ||
  fail 'missing cluster configuration error is not reported'

# A stub Kubernetes API server: the controller must load the kubeconfig, send
# its bearer token and start leader election through the coordination API. The
# stub records requests and answers NotFound, so the controller keeps retrying.
cat >"$work/stub.py" <<'PY'
import json, ssl, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

log = open(sys.argv[2], "a", buffering=1)
RESOURCES = {
    "v1": [("Namespace", "namespaces", False), ("Secret", "secrets", True),
           ("ConfigMap", "configmaps", True), ("ServiceAccount", "serviceaccounts", True),
           ("Event", "events", True), ("Pod", "pods", True), ("Service", "services", True)],
    "apps/v1": [("Deployment", "deployments", True)],
    "batch/v1": [("Job", "jobs", True)],
    "coordination.k8s.io/v1": [("Lease", "leases", True)],
    "rbac.authorization.k8s.io/v1": [("Role", "roles", True), ("RoleBinding", "rolebindings", True),
                                     ("ClusterRole", "clusterroles", False),
                                     ("ClusterRoleBinding", "clusterrolebindings", False)],
    "fleet.cattle.io/v1alpha1": [
        ("Bundle", "bundles", True),
        ("BundleDeployment", "bundledeployments", True),
        ("BundleNamespaceMapping", "bundlenamespacemappings", True),
        ("Cluster", "clusters", True),
        ("ClusterGroup", "clustergroups", True),
        ("ClusterRegistration", "clusterregistrations", True),
        ("ClusterRegistrationToken", "clusterregistrationtokens", True),
        ("Content", "contents", False),
        ("GitRepo", "gitrepos", True),
        ("GitRepoRestriction", "gitreporestrictions", True),
        ("HelmOp", "helmops", True),
        ("ImageScan", "imagescans", True),
        ("Policy", "policies", True),
        ("Schedule", "schedules", True),
    ],
}



class Handler(BaseHTTPRequestHandler):
    def handle_any(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        path = self.path.split("?")[0]
        log.write(f"{self.command} {path} auth={self.headers.get('Authorization', '')}\n")
        code, body = 404, {"kind": "Status", "apiVersion": "v1", "status": "Failure",
                           "reason": "NotFound", "code": 404}
        # Discovery: the core and Fleet API groups the controller maps at startup.
        if self.command == "GET" and path == "/api":
            code, body = 200, {"kind": "APIVersions", "versions": ["v1"],
                               "serverAddressByClientCIDRs": []}
        elif self.command == "GET" and path == "/apis":
            groups = [{"name": gv.split("/")[0],
                       "versions": [{"groupVersion": gv, "version": gv.split("/")[1]}],
                       "preferredVersion": {"groupVersion": gv, "version": gv.split("/")[1]}}
                      for gv in RESOURCES if "/" in gv]
            code, body = 200, {"kind": "APIGroupList", "apiVersion": "v1", "groups": groups}
        elif self.command == "GET" and path.removeprefix("/api/").removeprefix("/apis/") in RESOURCES:
            gv = path.removeprefix("/api/").removeprefix("/apis/")
            code, body = 200, {"kind": "APIResourceList", "groupVersion": gv, "resources": [
                {"name": plural, "singularName": "", "namespaced": namespaced, "kind": kind,
                 "verbs": ["create", "delete", "get", "list", "patch", "update", "watch"]}
                for kind, plural, namespaced in RESOURCES[gv]]}
        elif self.command == "GET":
            # Collections: empty lists, and watches that end without events.
            parts = path.strip("/").split("/")
            gv = "/".join(parts[1:2] if parts[0] == "api" else parts[1:3])
            rest = parts[2:] if parts[0] == "api" else parts[3:]
            if len(rest) >= 2 and rest[0] == "namespaces" and len(rest) in (3, 4):
                rest = rest[2:]
            kinds = {plural: kind for kind, plural, _ in RESOURCES.get(gv, [])}
            if len(rest) == 1 and rest[0] in kinds:
                if "watch=true" in self.path:
                    code, body = 200, None
                else:
                    code, body = 200, {"kind": kinds[rest[0]] + "List", "apiVersion": gv,
                                       "metadata": {"resourceVersion": "1"}, "items": []}
        data = b"" if body is None else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    do_GET = do_POST = do_PUT = handle_any

    def log_message(self, *args):
        pass


server = ThreadingHTTPServer(("0.0.0.0", 0), Handler)
tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls.load_cert_chain(sys.argv[3], sys.argv[4])
server.socket = tls.wrap_socket(server.socket, server_side=True)
open(sys.argv[1], "w").write(str(server.server_address[1]))
server.serve_forever()
PY
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
  -subj /CN=host.docker.internal -addext subjectAltName=DNS:host.docker.internal \
  -keyout "$work/stub.key" -out "$work/stub.crt" >/dev/null 2>&1 || fail 'stub certificate generation failed'
python3 "$work/stub.py" "$work/port" "$work/requests" "$work/stub.crt" "$work/stub.key" &
stub_pid=$!
i=0
until [ -s "$work/port" ]; do
  i=$((i + 1))
  [ "$i" -le 50 ] || fail 'stub API server did not start'
  sleep 0.1
done
port=$(cat "$work/port")

cat >"$work/kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: smoke
    cluster:
      server: https://host.docker.internal:$port
      certificate-authority-data: $(base64 <"$work/stub.crt" | tr -d '\n')
contexts:
  - name: smoke
    context:
      cluster: smoke
      user: smoke
current-context: smoke
users:
  - name: smoke
    user:
      token: verity-smoke-token
EOF
chmod 644 "$work/kubeconfig"

lease=/apis/coordination.k8s.io/v1/namespaces/cattle-fleet-system/leases
docker run -d --name "$container" --read-only --add-host host.docker.internal:host-gateway \
  -v "$work/kubeconfig:/kube/config:ro" \
  -e CATTLE_ELECTION_LEASE_DURATION=20s -e CATTLE_ELECTION_RENEW_DEADLINE=10s \
  -e CATTLE_ELECTION_RETRY_PERIOD=2s \
  "$image" --namespace cattle-fleet-system --kubeconfig /kube/config >/dev/null
i=0
until grep -Fx "POST $lease auth=Bearer verity-smoke-token" "$work/requests" >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -gt 60 ] || [ "$(docker inspect --format '{{.State.Running}}' "$container")" != true ]; then
    docker logs "$container" >"$work/controller.log" 2>&1 || true
    fail 'controller did not try to create its leader-election lease with the kubeconfig token'
  fi
  sleep 1
done
grep -E "^GET $lease/[a-z0-9.-]+ auth=Bearer verity-smoke-token\$" "$work/requests" >/dev/null ||
  fail 'controller did not look up its lease'
if grep -v 'auth=Bearer verity-smoke-token$' "$work/requests" >/dev/null; then
  fail 'controller sent an API request without the kubeconfig token'
fi
test "$(docker inspect --format '{{.State.Running}}' "$container")" = true ||
  fail 'controller exited while waiting for its lease'

docker stop -t 20 "$container" >/dev/null
code=$(docker inspect --format '{{.State.ExitCode}}' "$container")
docker logs "$container" >"$work/controller.log" 2>&1 || true
if grep -E '"level":"(panic|dpanic)"|^panic:' "$work/controller.log" >/dev/null; then
  fail 'controller panicked'
fi
[ "$code" -ne 137 ] || fail 'controller ignored SIGTERM for 20s'

printf 'SMOKE PASS image=%s\n' "$image"
