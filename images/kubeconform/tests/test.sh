#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
flavor=${2:-plain}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d)
server_pid=

cleanup() {
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

version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
[ -n "$version" ] || fail 'could not read the recipe version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/kubeconform"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'
if [ "$flavor" = fips ]; then
  godebug=fips140=only
else
  godebug=fips140=off
fi
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx "GODEBUG=$godebug" >/dev/null || fail "GODEBUG is not $godebug"

created=$(docker create "$image")
docker cp "$created:/usr/bin/kubeconform" "$work/kubeconform"
docker rm "$created" >/dev/null
if [ "$flavor" = fips ]; then
  go version -m "$work/kubeconform" | grep -q 'GOFIPS140=v1.0.0' ||
    fail 'fips flavor must be built with GOFIPS140=v1.0.0'
elif go version -m "$work/kubeconform" | grep -q 'GOFIPS140='; then
  fail 'plain flavor must not set GOFIPS140'
fi

docker run --rm --network none "$image" -v >"$work/version" 2>&1 ||
  fail "version failed: $(cat "$work/version")"
grep -Fx "v$version" "$work/version" >/dev/null ||
  fail "version does not report v$version: $(cat "$work/version")"

rc=0
docker run --rm --network none "$image" -definitely-invalid >"$work/invalid" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"

# Local schemas only: a reduced apps/v1 Deployment schema in kubeconform's
# {{.ResourceKind}}{{.KindSuffix}}.json naming. Nothing is fetched from the network.
mkdir -p "$work/schemas" "$work/manifests"
cat >"$work/schemas/deployment-apps-v1.json" <<'EOF'
{
  "type": "object",
  "required": ["apiVersion", "kind", "metadata", "spec"],
  "properties": {
    "apiVersion": {"type": "string", "enum": ["apps/v1"]},
    "kind": {"type": "string", "enum": ["Deployment"]},
    "metadata": {
      "type": "object",
      "required": ["name"],
      "properties": {"name": {"type": "string"}, "labels": {"type": "object"}}
    },
    "spec": {
      "type": "object",
      "required": ["selector", "template"],
      "additionalProperties": false,
      "properties": {
        "replicas": {"type": "integer", "minimum": 0},
        "selector": {"type": "object"},
        "template": {
          "type": "object",
          "properties": {
            "metadata": {"type": "object"},
            "spec": {
              "type": "object",
              "required": ["containers"],
              "properties": {
                "containers": {
                  "type": "array",
                  "minItems": 1,
                  "items": {
                    "type": "object",
                    "required": ["name", "image"],
                    "properties": {"name": {"type": "string"}, "image": {"type": "string"}}
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
EOF
cat >"$work/manifests/valid.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: verity-valid
spec:
  replicas: 2
  selector:
    matchLabels:
      app: verity
  template:
    metadata:
      labels:
        app: verity
    spec:
      containers:
        - name: web
          image: example.invalid/web:1
EOF
cat >"$work/manifests/invalid.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: verity-invalid
spec:
  replicas: two
  selector:
    matchLabels:
      app: verity
  template:
    spec:
      containers: []
EOF
cat >"$work/manifests/configmap.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: verity-unknown-schema
data:
  key: value
EOF
chmod 755 "$work/schemas" "$work/manifests"
chmod 644 "$work"/schemas/*.json "$work"/manifests/*.yaml

local_location='/schemas/{{ .ResourceKind }}{{ .KindSuffix }}.json'
validate() {
  docker run --rm --network none --read-only --cap-drop=ALL \
    -v "$work/schemas:/schemas:ro" -v "$work/manifests:/work:ro" "$image" \
    -schema-location "$local_location" -summary "$@"
}

validate valid.yaml >"$work/valid.out" 2>&1 ||
  fail "valid Deployment was rejected: $(cat "$work/valid.out")"
grep -F 'Summary: 1 resource found in 1 file - Valid: 1, Invalid: 0, Errors: 0, Skipped: 0' \
  "$work/valid.out" >/dev/null || fail "valid summary is wrong: $(cat "$work/valid.out")"

rc=0
validate invalid.yaml >"$work/invalid.out" 2>&1 || rc=$?
test "$rc" -eq 1 || fail "invalid Deployment exited $rc, expected 1: $(cat "$work/invalid.out")"
grep -F 'verity-invalid is invalid' "$work/invalid.out" >/dev/null ||
  fail "invalid Deployment was not reported: $(cat "$work/invalid.out")"
grep -F '/spec/replicas' "$work/invalid.out" >/dev/null ||
  fail "replicas type error is missing: $(cat "$work/invalid.out")"
grep -F '/spec/template/spec/containers' "$work/invalid.out" >/dev/null ||
  fail "empty containers error is missing: $(cat "$work/invalid.out")"

# A kind without a local schema is an error by default and skipped on request.
rc=0
validate configmap.yaml >"$work/missing.out" 2>&1 || rc=$?
test "$rc" -eq 1 || fail "missing schema exited $rc, expected 1: $(cat "$work/missing.out")"
grep -F 'could not find schema for ConfigMap' "$work/missing.out" >/dev/null ||
  fail "missing schema diagnostic is wrong: $(cat "$work/missing.out")"
validate -ignore-missing-schemas valid.yaml configmap.yaml >"$work/skip.out" 2>&1 ||
  fail "ignore-missing-schemas failed: $(cat "$work/skip.out")"
grep -F 'Summary: 2 resources found in 2 files - Valid: 1, Invalid: 0, Errors: 0, Skipped: 1' \
  "$work/skip.out" >/dev/null || fail "skip summary is wrong: $(cat "$work/skip.out")"

# Schema registry over HTTPS on the runner loopback, trusted through
# SSL_CERT_FILE. Exercises the TLS client (FIPS-approved ECDSA P-256 and
# AES-GCM under fips140=only for the fips flavor). Nothing leaves the runner.
mkdir -p "$work/tls"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -sha256 -nodes -days 1 \
  -subj /CN=127.0.0.1 -addext subjectAltName=IP:127.0.0.1 \
  -keyout "$work/tls/key.pem" -out "$work/tls/cert.pem" >/dev/null 2>&1 ||
  fail 'could not create the test certificate'
chmod 755 "$work/tls"
chmod 644 "$work/tls/cert.pem"
cat >"$work/server.py" <<'PY'
import functools
import http.server
import ssl
import sys

root, cert, key, port_file, log_file = sys.argv[1:6]


class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        with open(log_file, "a", encoding="ascii") as log:
            log.write(self.path + "\n")


server = http.server.ThreadingHTTPServer(
    ("127.0.0.1", 0), functools.partial(Handler, directory=root)
)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.minimum_version = ssl.TLSVersion.TLSv1_2
context.load_cert_chain(cert, key)
server.socket = context.wrap_socket(server.socket, server_side=True)
with open(port_file, "w", encoding="ascii") as out:
    out.write(str(server.server_port))
server.serve_forever()
PY
python3 "$work/server.py" "$work/schemas" "$work/tls/cert.pem" "$work/tls/key.pem" \
  "$work/port" "$work/requests.log" 2>"$work/server.err" &
server_pid=$!
attempt=0
until [ -s "$work/port" ]; do
  kill -0 "$server_pid" 2>/dev/null || fail "schema server exited early: $(cat "$work/server.err")"
  attempt=$((attempt + 1))
  [ "$attempt" -lt 20 ] || fail 'schema server did not start'
  sleep 1
done
port=$(cat "$work/port")
https_location="https://127.0.0.1:$port/{{ .ResourceKind }}{{ .KindSuffix }}.json"

docker run --rm --network host --read-only --cap-drop=ALL \
  -e SSL_CERT_FILE=/tls/cert.pem -v "$work/tls/cert.pem:/tls/cert.pem:ro" \
  -v "$work/manifests:/work:ro" "$image" \
  -schema-location "$https_location" -summary valid.yaml >"$work/https.out" 2>&1 ||
  fail "HTTPS schema validation failed: $(cat "$work/https.out")"
grep -F 'Valid: 1, Invalid: 0, Errors: 0' "$work/https.out" >/dev/null ||
  fail "HTTPS summary is wrong: $(cat "$work/https.out")"
grep -Fx '/deployment-apps-v1.json' "$work/requests.log" >/dev/null ||
  fail 'schema server never served the Deployment schema'

# Negative: the default CA bundle does not trust the test certificate.
rc=0
docker run --rm --network host --read-only --cap-drop=ALL \
  -v "$work/manifests:/work:ro" "$image" \
  -schema-location "$https_location" valid.yaml >"$work/untrusted.out" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'untrusted schema server unexpectedly succeeded'
grep -F 'certificate signed by unknown authority' "$work/untrusted.out" >/dev/null ||
  fail "untrusted certificate diagnostic is missing: $(cat "$work/untrusted.out")"

printf 'SMOKE PASS image=%s flavor=%s\n' "$image" "$flavor"
