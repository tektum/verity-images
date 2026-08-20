#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
: "${IMAGE_VERSION:?IMAGE_VERSION is required}"
work=$(mktemp -d)
api_pid=

cleanup() {
  if [ -n "$api_pid" ]; then
    kill "$api_pid" >/dev/null 2>&1 || true
    wait "$api_pid" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/controller"]'
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532
docker run --rm --network none "$image" --version 2>&1 |
  grep -Fx "controller version: v${IMAGE_VERSION}" >/dev/null || fail 'controller version mismatch'
docker run --rm --network none --entrypoint /usr/bin/kubeseal "$image" --version 2>&1 |
  grep -Fx "kubeseal version: v${IMAGE_VERSION}" >/dev/null || fail 'kubeseal version mismatch'

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=smoke \
  -keyout "$work/key.pem" -out "$work/cert.pem" >/dev/null 2>&1
chmod 644 "$work/key.pem" "$work/cert.pem"
cat > "$work/secret.yaml" <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: smoke
  namespace: default
stringData:
  password: smoke-value
EOF

docker run --rm --network none -i \
  -v "$work/cert.pem:/work/cert.pem:ro" \
  --entrypoint /usr/bin/kubeseal "$image" \
  --cert /work/cert.pem < "$work/secret.yaml" > "$work/sealed.json"
grep -F '"encryptedData"' "$work/sealed.json" >/dev/null || fail 'encrypted fixture is missing encrypted data'

docker run --rm --network none -i \
  -v "$work/key.pem:/work/key.pem:ro" \
  --entrypoint /usr/bin/kubeseal "$image" \
  --recovery-unseal --recovery-private-key /work/key.pem \
  < "$work/sealed.json" > "$work/unsealed.json"
grep -Eq '"password":[[:space:]]*"c21va2UtdmFsdWU="' "$work/unsealed.json" ||
  fail 'decrypted fixture does not contain the original secret'

cat > "$work/api.py" <<'PY'
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def send_json(self, status, body):
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path == "/api/v1/namespaces/kube-system/services/sealed-secrets-controller":
            self.send_json(200, {"apiVersion": "v1", "kind": "Service", "metadata": {"name": "sealed-secrets-controller", "namespace": "kube-system"}, "spec": {"ports": [{"name": "http", "port": 8080}]}})
            return
        self.send_error(404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        if self.path.endswith("/proxy/v1/verify") and b'"encryptedData"' in body:
            self.send_json(200, {})
            return
        self.send_error(400)

    def log_message(self, _format, *_args):
        pass


server = ThreadingHTTPServer(("0.0.0.0", 0), Handler)
with open(sys.argv[1], "w", encoding="utf-8") as port_file:
    port_file.write(str(server.server_port))
server.serve_forever()
PY
python3 "$work/api.py" "$work/port" &
api_pid=$!
while [ ! -s "$work/port" ]; do
  kill -0 "$api_pid" 2>/dev/null || fail 'fake Kubernetes API failed to start'
done
port=$(cat "$work/port")
cat > "$work/kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: smoke
    cluster:
      server: http://host.docker.internal:$port
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
chmod 644 "$work/kubeconfig"
docker run --rm -i --add-host host.docker.internal:host-gateway \
  -v "$work/kubeconfig:/work/kubeconfig:ro" \
  --entrypoint /usr/bin/kubeseal "$image" \
  --validate --kubeconfig /work/kubeconfig < "$work/sealed.json" ||
  fail 'sealed fixture validation failed'

printf 'not a certificate\n' > "$work/invalid.pem"
chmod 644 "$work/invalid.pem"
if invalid_output=$(docker run --rm --network none -i \
  -v "$work/invalid.pem:/work/invalid.pem:ro" \
  --entrypoint /usr/bin/kubeseal "$image" \
  --cert /work/invalid.pem < "$work/secret.yaml" 2>&1); then
  fail 'invalid certificate unexpectedly succeeded'
fi
case "$invalid_output" in
  *error:*certificat*) ;;
  *)
    printf '%s\n' "$invalid_output" >&2
    fail 'invalid certificate diagnostic missing'
    ;;
esac

printf 'SMOKE PASS image=%s\n' "$image"
