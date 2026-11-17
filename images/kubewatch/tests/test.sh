#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
config="$here/../apko.yaml"
version=$(sed -n 's/^    - kubewatch=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
work=$(mktemp -d)
receiver=

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  [ -z "$receiver" ] || kill "$receiver" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail 'could not read the pinned kubewatch version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/kubewatch"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

docker run --rm --network none "$image" --help >"$work/help" 2>&1 || fail 'help failed'
grep -F 'kubewatch is a Kubernetes watcher' "$work/help" >/dev/null ||
  fail "help does not describe kubewatch: $(cat "$work/help")"

rc=0
docker run --rm --network none "$image" definitely-invalid >"$work/invalid" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid command unexpectedly succeeded'
grep -F 'unknown command "definitely-invalid"' "$work/invalid" >/dev/null ||
  fail "invalid command diagnostic is missing: $(cat "$work/invalid")"

# Without in-cluster credentials or a kubeconfig the watcher refuses to start.
rc=0
docker run --rm --network none --read-only --tmpfs /home/nonroot:rw,uid=65532,gid=65532 \
  "$image" >"$work/nocluster" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'watcher started without Kubernetes configuration'
grep -F 'Can not get kubernetes config' "$work/nocluster" >/dev/null ||
  fail "missing Kubernetes configuration diagnostic: $(cat "$work/nocluster")"

# Configure a webhook handler through the CLI and deliver a test notification to
# a local receiver, then assert the JSON event the image actually sent.
mkdir -p "$work/home"
chmod 0777 "$work/home"
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
cat >"$work/receiver.py" <<'EOF'
import http.server
import sys

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(sys.argv[2], "ab") as out:
            out.write(self.path.encode() + b" " + self.headers.get("Content-Type", "").encode() + b" " + body + b"\n")
        self.send_response(200)
        self.end_headers()

    def log_message(self, *args):
        pass

http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
EOF
python3 "$work/receiver.py" "$port" "$work/hook.log" &
receiver=$!
ready=0
for _ in $(seq 1 50); do
  if python3 -c 'import socket, sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 1)' "$port" 2>/dev/null; then
    ready=1
    break
  fi
  sleep 0.1
done
test "$ready" = 1 || fail 'webhook receiver did not start'

kw() {
  docker run --rm --network host --read-only --cap-drop=ALL -e HOME=/h \
    -v "$work/home:/h" "$image" "$@"
}

kw config add webhook --url "http://127.0.0.1:$port/kubewatch-smoke" >"$work/add.out" 2>&1 ||
  fail "config add webhook failed: $(cat "$work/add.out")"
grep -F "url: http://127.0.0.1:$port/kubewatch-smoke" "$work/home/.kubewatch.yaml" >/dev/null ||
  fail 'webhook URL was not written to .kubewatch.yaml'
kw config view >"$work/view.out" 2>&1 || fail 'config view failed'
grep -F "http://127.0.0.1:$port/kubewatch-smoke" "$work/view.out" >/dev/null ||
  fail "config view does not show the webhook: $(cat "$work/view.out")"

kw config test >"$work/test.out" 2>&1 || fail "config test failed: $(cat "$work/test.out")"
grep -F 'Message successfully sent' "$work/test.out" >/dev/null ||
  fail "config test did not report delivery: $(cat "$work/test.out")"
test -s "$work/hook.log" || fail 'webhook receiver got no request'
grep -F '/kubewatch-smoke application/json' "$work/hook.log" >/dev/null ||
  fail "unexpected webhook path or content type: $(cat "$work/hook.log")"
grep -F '"eventmeta":{"kind":"testKind","name":"testResource","namespace":"testNamespace","reason":"Tested"}' \
  "$work/hook.log" >/dev/null || fail "unexpected webhook event: $(cat "$work/hook.log")"

# With a kubeconfig and a pod watch configured the daemon keeps running and
# serves Prometheus metrics on its documented port 2112.
cat >"$work/kubeconfig" <<'EOF'
apiVersion: v1
kind: Config
clusters:
- name: smoke
  cluster:
    server: http://127.0.0.1:1
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

mkdir -p "$work/daemon/.kube"
cp "$work/kubeconfig" "$work/daemon/.kube/config"
sed 's/^  pod: false$/  pod: true/' "$work/home/.kubewatch.yaml" >"$work/daemon/.kubewatch.yaml"
grep -Fx '  pod: true' "$work/daemon/.kubewatch.yaml" >/dev/null || fail 'could not enable the pod watch'
chmod -R a+rwX "$work/daemon"
name="kubewatch-smoke-$$"
docker run -d --name "$name" --read-only --cap-drop=ALL -e HOME=/h \
  -p 127.0.0.1::2112 -v "$work/daemon:/h" "$image" >/dev/null || fail 'daemon start failed'
cleanup_daemon() {
  docker rm -f "$name" >/dev/null 2>&1 || true
}
metrics=
for _ in $(seq 1 60); do
  hostport=$(docker port "$name" 2112/tcp 2>/dev/null | head -n 1 || true)
  if [ -n "$hostport" ] && curl -fsS "http://$hostport/metrics" >"$work/metrics" 2>/dev/null; then
    metrics=1
    break
  fi
  sleep 0.5
done
if [ -z "$metrics" ]; then
  docker logs "$name" >&2 || true
  cleanup_daemon
  fail 'metrics endpoint did not become ready'
fi
grep -E '^go_goroutines [0-9]+' "$work/metrics" >/dev/null ||
  { cleanup_daemon; fail 'metrics endpoint did not serve Prometheus metrics'; }
docker logs "$name" >"$work/daemon.log" 2>&1 || true
grep -F 'Starting metrics server on port :2112' "$work/daemon.log" >/dev/null ||
  { cleanup_daemon; fail "missing metrics server log: $(cat "$work/daemon.log")"; }
test "$(docker inspect --format '{{.State.Running}}' "$name")" = true ||
  { cleanup_daemon; fail 'daemon exited while watching'; }
docker stop -t 10 "$name" >/dev/null || { cleanup_daemon; fail 'daemon did not stop on SIGTERM'; }
cleanup_daemon

echo 'SMOKE PASS'
