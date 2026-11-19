#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container=verity-fleet-agent-$$
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
  if [ -f "$work/agent.log" ]; then
    tail -n 20 "$work/agent.log" >&2
  fi
  exit 1
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 1000 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/fleetagent"]' || fail 'unexpected entrypoint'
# The Fleet charts and the agent manifest run the binary by name.
docker run --rm --network none --entrypoint fleetagent "$image" --version >/dev/null 2>&1 ||
  fail 'fleetagent is not on PATH'

docker run --rm --network none --read-only "$image" --version >"$work/version" 2>&1 ||
  fail 'fleetagent --version failed'
grep -E '^fleet-agent version v[0-9]+\.[0-9]+\.[0-9]+ \([0-9a-f]{40}\)$' "$work/version" >/dev/null ||
  fail 'fleetagent version output is missing'
docker run --rm --network none --read-only "$image" --help >"$work/help" 2>&1 || fail 'fleetagent --help failed'
for flag in --namespace --kubeconfig --agent-scope --checkin-interval --leader-elect; do
  grep -F -- "$flag" "$work/help" >/dev/null || fail "fleetagent --help does not list $flag"
done

# Negative: an unknown flag must exit non-zero.
if docker run --rm --network none --read-only "$image" --no-such-flag >/dev/null 2>&1; then
  fail 'unknown flag unexpectedly succeeded'
fi

# Negative: without a namespace the agent must exit with the documented error.
if docker run --rm --network none --read-only "$image" >"$work/nonamespace" 2>&1; then
  fail 'agent started without a namespace'
fi
grep -F -- '--namespace or env NAMESPACE is required to be set' "$work/nonamespace" >/dev/null ||
  fail 'missing namespace error is not reported'

# Negative: with a namespace but no kubeconfig or in-cluster environment it must exit, not hang.
status=0
timeout 60 docker run --rm --network none --read-only -e NAMESPACE=cattle-fleet-system \
  -e CATTLE_ELECTION_LEASE_DURATION=20s -e CATTLE_ELECTION_RENEW_DEADLINE=10s \
  -e CATTLE_ELECTION_RETRY_PERIOD=2s "$image" >"$work/noconfig" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail 'agent started without any cluster configuration'
[ "$status" -ne 124 ] || fail 'agent hung without any cluster configuration instead of exiting'
grep -F 'unable to load in-cluster configuration' "$work/noconfig" >/dev/null ||
  fail 'missing cluster configuration error is not reported'

# A stub Kubernetes API server: the agent must load the kubeconfig, send its
# bearer token and start leader election through the coordination API. The
# stub records requests and answers NotFound, so the agent keeps retrying.
cat >"$work/stub.py" <<'PY'
import json, ssl, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

log = open(sys.argv[2], "a", buffering=1)


class Handler(BaseHTTPRequestHandler):
    def handle_any(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        log.write(f"{self.command} {self.path.split('?')[0]} auth={self.headers.get('Authorization', '')}\n")
        data = json.dumps({"kind": "Status", "apiVersion": "v1", "status": "Failure",
                           "reason": "NotFound", "code": 404}).encode()
        self.send_response(404)
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
  -e CATTLE_ELECTION_RETRY_PERIOD=2s -e AGENT_SCOPE=smoke -e CHECKIN_INTERVAL=15m \
  "$image" --namespace cattle-fleet-system --kubeconfig /kube/config >/dev/null
i=0
until grep -Fx "POST $lease auth=Bearer verity-smoke-token" "$work/requests" >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -gt 60 ] || [ "$(docker inspect --format '{{.State.Running}}' "$container")" != true ]; then
    docker logs "$container" >"$work/agent.log" 2>&1 || true
    fail 'agent did not try to create its leader-election lease with the kubeconfig token'
  fi
  sleep 1
done
grep -Fx "GET $lease/fleet-agent auth=Bearer verity-smoke-token" "$work/requests" >/dev/null ||
  fail 'agent did not look up its fleet-agent lease'
if grep -v 'auth=Bearer verity-smoke-token$' "$work/requests" >/dev/null; then
  fail 'agent sent an API request without the kubeconfig token'
fi
test "$(docker inspect --format '{{.State.Running}}' "$container")" = true ||
  fail 'agent exited while waiting for its lease'

docker stop -t 20 "$container" >/dev/null
code=$(docker inspect --format '{{.State.ExitCode}}' "$container")
docker logs "$container" >"$work/agent.log" 2>&1 || true
if grep -E '"level":"(panic|dpanic)"|^panic:' "$work/agent.log" >/dev/null; then
  fail 'agent panicked'
fi
[ "$code" -ne 137 ] || fail 'agent ignored SIGTERM for 20s'

printf 'SMOKE PASS image=%s\n' "$image"
