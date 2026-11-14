#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
server_pid=
label=verity.test=rabbitmq-messaging-topology-operator-$$

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -fv >/dev/null 2>&1 || true
  if [ -n "$server_pid" ]; then
    kill "$server_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/manager"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'

run() {
  docker run --rm --label "$label" --read-only --cap-drop=ALL "$@"
}

run --network none "$image" --help >"$work/help" 2>&1 || fail "--help failed: $(cat "$work/help")"
for flag in -health-probe-bind-address -metrics-bind-address -leader-elect \
  -webhook-cert-path -zap-log-level; do
  grep -F -- "$flag" "$work/help" >/dev/null || fail "--help does not list $flag"
done
# Upstream manifests and the Helm chart run the hardcoded command /manager.
run --network none --entrypoint /manager "$image" --help >"$work/help-compat" 2>&1 ||
  fail "/manager is not executable: $(cat "$work/help-compat")"
grep -Fx 'Usage of /manager:' "$work/help-compat" >/dev/null ||
  fail "/manager usage header is wrong: $(head -n 1 "$work/help-compat")"
sed 1d "$work/help" >"$work/help.body"
sed 1d "$work/help-compat" >"$work/help-compat.body"
cmp -s "$work/help.body" "$work/help-compat.body" || fail '/manager is not the operator binary'

rc=0
run --network none "$image" --definitely-invalid >"$work/invalid" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"

# Negative: outside a pod (no OPERATOR_NAMESPACE, no service account) startup
# stops with the documented error instead of crash looping.
rc=0
run --network none "$image" >"$work/no-namespace" 2>&1 || rc=$?
test "$rc" -eq 1 || fail "start without a namespace exited $rc: $(cat "$work/no-namespace")"
grep -F 'unable to find operator namespace' "$work/no-namespace" >/dev/null ||
  fail "namespace diagnostic is missing: $(cat "$work/no-namespace")"

# Negative: a namespace but no kubeconfig and no in-cluster environment.
rc=0
run --network none -e OPERATOR_NAMESPACE=rabbitmq-system "$image" >"$work/no-config" 2>&1 || rc=$?
test "$rc" -eq 1 || fail "start without a kubeconfig exited $rc: $(cat "$work/no-config")"
grep -F 'unable to get kubeconfig' "$work/no-config" >/dev/null ||
  fail "kubeconfig diagnostic is missing: $(cat "$work/no-config")"

# Startup reads a kubeconfig and talks to the API server it names. A stub API
# server on the runner loopback answers 404 to everything, so the manager must
# fail API discovery with exit 1 after querying the configured server.
cat >"$work/apiserver.py" <<'PY'
import http.server
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(sys.argv[2], "a", encoding="ascii") as log:
            log.write(self.path + "\n")
        body = b'{"kind":"Status","apiVersion":"v1","status":"Failure","reason":"NotFound","code":404}'
        self.send_response(404)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w", encoding="ascii") as port_file:
    port_file.write(str(server.server_port))
server.serve_forever()
PY
python3 "$work/apiserver.py" "$work/port" "$work/requests.log" &
server_pid=$!
attempt=0
until [ -s "$work/port" ]; do
  kill -0 "$server_pid" 2>/dev/null || fail 'stub API server exited early'
  attempt=$((attempt + 1))
  [ "$attempt" -lt 20 ] || fail 'stub API server did not start'
  sleep 1
done
port=$(cat "$work/port")
cat >"$work/kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: stub
    cluster:
      server: http://127.0.0.1:$port
users:
  - name: verity
    user: {}
contexts:
  - name: stub
    context:
      cluster: stub
      user: verity
current-context: stub
EOF
chmod 644 "$work/kubeconfig"
rc=0
run --network host -e OPERATOR_NAMESPACE=rabbitmq-system -e KUBECONFIG=/config/kubeconfig \
  -v "$work/kubeconfig:/config/kubeconfig:ro" "$image" >"$work/stub" 2>&1 || rc=$?
test "$rc" -eq 1 || fail "start against the stub API server exited $rc: $(cat "$work/stub")"
grep -F 'unable to start manager' "$work/stub" >/dev/null ||
  fail "manager start diagnostic is missing: $(cat "$work/stub")"
grep -F 'failed to get server groups' "$work/stub" >/dev/null ||
  fail "API discovery diagnostic is missing: $(cat "$work/stub")"
for path in /api /apis; do
  grep -Fx "$path" "$work/requests.log" >/dev/null ||
    fail "stub API server saw no $path discovery request: $(cat "$work/requests.log")"
done

printf 'SMOKE PASS image=%s\n' "$image"
