#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-clickhouse-metrics-exporter-test-$$"
tmp=$(mktemp -d)
api_pid=

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  if [ -n "$api_pid" ]; then kill "$api_pid" 2>/dev/null || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  docker logs "$container" >&2 2>/dev/null || true
  exit 1
}

test "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532 ||
  fail 'image must run as UID 65532'
test "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/clickhouse-operator-metrics-exporter"]' ||
  fail 'unexpected entrypoint'

docker run --rm "$image" -version 2>&1 | grep -E '^v?0\.27\.[0-9]+$' >/dev/null ||
  fail 'unexpected exporter version'

docker run --rm "$image" -help >"$tmp/help.log" 2>&1 || true
for flag in -config -kubeconfig -master -metrics-endpoint -chi-list-endpoint -version; do
  grep -E "^[[:space:]]+$flag( |\$)" "$tmp/help.log" >/dev/null ||
    fail "expected flag $flag missing from -help"
done

# Minimal fake Kubernetes API server serving the clickhouse.altinity.com CRDs
# the exporter lists and watches on startup.
cat >"$tmp/apiserver.py" <<'PY'
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

KINDS = {
    "clickhouseoperatorconfigurations": "ClickHouseOperatorConfigurationList",
    "clickhouseinstallations": "ClickHouseInstallationList",
}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        path = self.path.split("?")[0].rstrip("/")
        resource = path.rsplit("/", 1)[-1]
        if not path.startswith("/apis/clickhouse.altinity.com/v1") or resource not in KINDS:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        if "watch=true" in self.path:
            self.wfile.flush()
            time.sleep(60)
            return
        self.wfile.write(json.dumps({
            "apiVersion": "clickhouse.altinity.com/v1",
            "kind": KINDS[resource],
            "metadata": {"resourceVersion": "1"},
            "items": [],
        }).encode())

server = ThreadingHTTPServer(("0.0.0.0", 0), Handler)
with open(sys.argv[1], "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
PY
python3 "$tmp/apiserver.py" "$tmp/api-port" &
api_pid=$!
for _ in $(seq 1 50); do
  test -s "$tmp/api-port" && break
  sleep 0.1
done
test -s "$tmp/api-port" || fail 'fake apiserver did not start'
api_port=$(cat "$tmp/api-port")

cat >"$tmp/kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: fake
    cluster:
      server: http://host.docker.internal:$api_port
users:
  - name: fake
    user:
      token: smoke
contexts:
  - name: fake
    context:
      cluster: fake
      user: fake
current-context: fake
EOF
chmod 644 "$tmp/kubeconfig"

docker run --name "$container" -d --read-only \
  --tmpfs /tmp:uid=65532,gid=65532 \
  --add-host host.docker.internal:host-gateway \
  -v "$tmp/kubeconfig:/etc/exporter/kubeconfig:ro" \
  -p 127.0.0.1::8888 "$image" \
  -kubeconfig /etc/exporter/kubeconfig >/dev/null
port=$(docker port "$container" 8888/tcp | awk -F: 'NR == 1 { print $NF }')
test -n "$port" || fail 'metrics port not published'
base="http://127.0.0.1:$port"

i=0
until curl -fsS --max-time 5 "$base/chi" >"$tmp/chi.json" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'exporter REST endpoint never became ready'
  [ "$(docker inspect -f '{{.State.Running}}' "$container")" = true ] || fail 'exporter exited'
  sleep 1
done
test "$(cat "$tmp/chi.json")" = '[]' || fail 'unexpected initial watched CHI list'

# Register a watched CHI (as the operator would) whose single host is
# unreachable; the exporter must then report fetch errors for it on /metrics.
cr='{"type":"cr","cr":{"namespace":"smoke","name":"demo","clusters":[{"name":"c1","hosts":[{"name":"h0","hostname":"127.0.0.1","httpPort":1,"tcpPort":1}]}]}}'
test "$(curl -sS -o /dev/null -w '%{http_code}' -X POST -d "$cr" "$base/chi")" = 200 ||
  fail 'registering a CHI failed'
curl -fsS "$base/chi" | grep -F '"name":"demo"' >/dev/null || fail 'registered CHI not listed'

curl -fsS --max-time 30 "$base/metrics" >"$tmp/metrics" || fail '/metrics request failed'
grep -E '^go_info\{' "$tmp/metrics" >/dev/null || fail 'go runtime metrics missing'
grep -F '# TYPE chi_clickhouse_metric_fetch_errors gauge' "$tmp/metrics" >/dev/null ||
  fail 'chi fetch error metric family missing'
grep -E '^chi_clickhouse_metric_fetch_errors\{chi="demo",fetch_type="system_metrics",hostname="127.0.0.1",namespace="smoke"\} 1$' \
  "$tmp/metrics" >/dev/null || { cat "$tmp/metrics" >&2; fail 'expected fetch error sample missing'; }

[ "$(docker inspect -f '{{.State.Running}}' "$container")" = true ] || fail 'exporter died during scrape'

# Negative: invalid CR registrations are rejected.
test "$(curl -sS -o /dev/null -w '%{http_code}' -X POST -d '{"type":"cr","cr":{}}' "$base/chi")" = 406 ||
  fail 'invalid CR was not rejected'
test "$(curl -sS -o /dev/null -w '%{http_code}' "$base/nope")" = 404 ||
  fail 'unknown path did not 404'

# Negative: without a kubeconfig or in-cluster env the exporter must refuse to start.
if docker run --rm "$image" >"$tmp/start.log" 2>&1; then
  fail 'exporter unexpectedly started without a kubeconfig'
fi
grep -F 'Unable to build kubeconf' "$tmp/start.log" >/dev/null ||
  { cat "$tmp/start.log" >&2; fail 'missing no-kubeconfig error'; }

if docker run --rm "$image" -no-such-flag >"$tmp/flag.log" 2>&1; then
  fail 'unknown flag unexpectedly succeeded'
fi
grep -F 'flag provided but not defined: -no-such-flag' "$tmp/flag.log" >/dev/null ||
  fail 'unknown flag error missing'

printf 'SMOKE PASS image=%s\n' "$image"
