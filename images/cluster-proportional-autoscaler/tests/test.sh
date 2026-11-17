#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
config="$(dirname "$0")/../apko.yaml"
version=$(sed -n 's/^    - cluster-proportional-autoscaler=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
python_index='docker.io/library/python:3.13-alpine@sha256:9ef1a599f863231c3d91e941389bfdc4a2d6070557243d54df1a4e57015b960e'
suffix="verity-cpa-$$"
api="$suffix-api"
network="$suffix-network"
work=$(mktemp -d)

cleanup() {
  docker rm -f "$api" "$suffix-linear" "$suffix-ladder" "$suffix-bad" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -n "$version" ] || fail 'could not read the pinned cluster-proportional-autoscaler version'

# OCI contract of registry.k8s.io/cpa/cluster-proportional-autoscaler:v$version.
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65535:65535 ||
  fail "unexpected OCI user: $(docker image inspect --format '{{.Config.User}}' "$image")"
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/cluster-proportional-autoscaler"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" >"$work/env"
grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' "$work/env" >/dev/null ||
  fail "SSL_CERT_FILE is not set: $(cat "$work/env")"
test "$(docker image inspect --format '{{json .Config.ExposedPorts}}' "$image")" = null ||
  fail 'unexpected exposed ports'

# The upstream /cluster-proportional-autoscaler path resolves to the packaged binary.
docker run --rm --network none --entrypoint /usr/bin/cluster-proportional-autoscaler "$image" \
  --version >"$work/version-direct" 2>&1 || fail "direct binary failed: $(cat "$work/version-direct")"

docker run --rm --network none "$image" --version >"$work/version" 2>&1 ||
  fail "version failed: $(cat "$work/version")"
grep -Fx "v$version" "$work/version" >/dev/null ||
  fail "version does not report v$version: $(cat "$work/version")"
cmp -s "$work/version" "$work/version-direct" ||
  fail 'the compat path and /usr/bin binary report different versions'

# Flag validation: every required parameter is reported and the process exits non-zero.
rc=0
docker run --rm --network none "$image" >"$work/noargs" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'missing --target/--configmap unexpectedly succeeded'
for line in '--target parameter cannot be empty' '--configmap parameter cannot be empty' \
  '--namespace parameter not set and failed to fallback' 'failed to validate all input parameters'; do
  grep -F -- "$line" "$work/noargs" >/dev/null || fail "missing diagnostic '$line': $(cat "$work/noargs")"
done

rc=0
docker run --rm --network none "$image" --target=deployment/web --namespace=default \
  >"$work/noconfigmap" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'missing --configmap unexpectedly succeeded'
grep -F -- '--configmap parameter cannot be empty' "$work/noconfigmap" >/dev/null ||
  fail "missing --configmap diagnostic: $(cat "$work/noconfigmap")"
if grep -F -- '--target parameter cannot be empty' "$work/noconfigmap" >/dev/null; then
  fail "a provided --target was reported as empty: $(cat "$work/noconfigmap")"
fi

rc=0
docker run --rm --network none "$image" --configmap=params --namespace=default \
  --target=daemonset/web >"$work/badtarget" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'unsupported target kind unexpectedly succeeded'
grep -F 'Target format error' "$work/badtarget" >/dev/null ||
  fail "unsupported target diagnostic is missing: $(cat "$work/badtarget")"

rc=0
docker run --rm --network none "$image" --definitely-invalid >"$work/badflag" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'unknown flag unexpectedly succeeded'
grep -F 'unknown flag: --definitely-invalid' "$work/badflag" >/dev/null ||
  fail "unknown flag diagnostic is missing: $(cat "$work/badflag")"

# Without a service account the in-cluster client cannot be built.
rc=0
docker run --rm --network none "$image" --configmap=params --namespace=default \
  --target=deployment/web >"$work/nocluster" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'running outside a cluster unexpectedly succeeded'
grep -F 'KUBERNETES_SERVICE_HOST and KUBERNETES_SERVICE_PORT must be defined' "$work/nocluster" \
  >/dev/null || fail "missing in-cluster diagnostic: $(cat "$work/nocluster")"

image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")

# Pull a pinned helper index by its per-platform child digest. A classic Docker
# image store cannot bind an index digest to a second platform's image, so the
# index bytes are verified against the pin before a child is chosen, which keeps
# the pin authoritative.
resolve_helper() {
  helper_index=$1
  helper_raw=$(docker buildx imagetools inspect --raw "$helper_index") ||
    fail 'cannot inspect helper image index'
  [ "sha256:$(printf '%s' "$helper_raw" | sha256sum | cut -d' ' -f1)" = "${helper_index#*@}" ] ||
    fail 'helper image index digest mismatch'
  helper_digest=$(printf '%s' "$helper_raw" |
    jq -r --arg arch "$image_arch" '
      [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
      | if length == 1 then .[0] else empty end') ||
    fail 'cannot resolve helper image digest'
  case $helper_digest in
    sha256:*) ;;
    *) fail "no unique linux/$image_arch helper image in $helper_index" ;;
  esac
  helper=${helper_index%%:*}@$helper_digest
  docker pull --quiet --platform "linux/$image_arch" "$helper" >/dev/null ||
    fail 'cannot pull helper image'
}
resolve_helper "$python_index"
python=$helper

# In-cluster configuration always speaks HTTPS to KUBERNETES_SERVICE_HOST with
# the service account CA and token, so the fixture serves TLS for "api".
mkdir -p "$work/pki" "$work/sa"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=verity-cpa-ca' \
  -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' \
  -keyout "$work/pki/ca.key" -out "$work/pki/ca.crt" 2>/dev/null || fail 'cannot create the CA'
openssl req -newkey rsa:2048 -nodes -subj '/CN=api' \
  -keyout "$work/pki/api.key" -out "$work/pki/api.csr" 2>/dev/null || fail 'cannot create the API key'
cat >"$work/pki/ext" <<'EXT'
subjectAltName=DNS:api
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid
EXT
openssl x509 -req -in "$work/pki/api.csr" -CA "$work/pki/ca.crt" -CAkey "$work/pki/ca.key" \
  -CAcreateserial -days 1 -extfile "$work/pki/ext" -out "$work/pki/api.crt" 2>/dev/null ||
  fail 'cannot sign the API certificate'
cp "$work/pki/ca.crt" "$work/sa/ca.crt"
printf 'verity-token' >"$work/sa/token"
printf 'default' >"$work/sa/namespace"

# A minimal Kubernetes API fixture. Nodes: two Ready schedulable nodes with 4
# CPUs each, one cordoned node and one NotReady node that must not count.
# Scale subresources: deployment/web at 1 replica, replicaset/db at 5.
# ConfigMaps: "linear" holds linear params, "bad" holds invalid params and
# "ladder" is absent until the autoscaler creates it from --default-params.
# Every request is logged with its method, path and JSON body.
cat >"$work/api.py" <<'PY'
import json
import ssl
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOCK = threading.Lock()


# The autoscaler sends Kubernetes protobuf (application/vnd.kubernetes.protobuf):
# a "k8s\0" magic and a runtime.Unknown envelope around the object. Decode the
# few fields this fixture needs into the equivalent JSON object.
def pb_fields(buf):
    i = 0
    while i < len(buf):
        key, i = pb_varint(buf, i)
        num, wire = key >> 3, key & 7
        if wire == 0:
            value, i = pb_varint(buf, i)
        elif wire == 2:
            size, i = pb_varint(buf, i)
            value, i = buf[i:i + size], i + size
        else:
            raise ValueError("unsupported protobuf wire type %d" % wire)
        yield num, value


def pb_varint(buf, i):
    value = shift = 0
    while True:
        byte = buf[i]
        i += 1
        value |= (byte & 0x7F) << shift
        shift += 7
        if not byte & 0x80:
            return value, i


def pb_decode(body):
    if not body.startswith(b"k8s\x00"):
        raise ValueError("body is not a Kubernetes protobuf envelope")
    obj, raw = {}, b""
    for num, value in pb_fields(body[4:]):
        if num == 1:
            for tnum, tvalue in pb_fields(value):
                obj[{1: "apiVersion", 2: "kind"}[tnum]] = tvalue.decode()
        elif num == 2:
            raw = value
    meta, spec, data = {}, {}, {}
    for num, value in pb_fields(raw):
        if num == 1:
            for mnum, mvalue in pb_fields(value):
                if mnum in (1, 3):
                    meta[{1: "name", 3: "namespace"}[mnum]] = mvalue.decode()
        elif num == 2 and obj.get("kind") == "Scale":
            for snum, svalue in pb_fields(value):
                if snum == 1:
                    spec["replicas"] = svalue
        elif num == 2 and obj.get("kind") == "ConfigMap":
            entry = dict(pb_fields(value))
            data[entry[1].decode()] = entry[2].decode()
    obj["metadata"] = meta
    if obj.get("kind") == "Scale":
        obj["spec"] = spec
    if obj.get("kind") == "ConfigMap":
        obj["data"] = data
    return obj


def node(name, cpu, ready=True, unschedulable=False):
    return {
        "metadata": {"name": name, "resourceVersion": "1", "uid": "uid-" + name},
        "spec": {"unschedulable": unschedulable},
        "status": {
            "allocatable": {"cpu": cpu},
            "capacity": {"cpu": cpu},
            "conditions": [{"type": "Ready", "status": "True" if ready else "False"}],
        },
    }


NODES = [
    node("ready-a", "4"),
    node("ready-b", "4000m"),
    node("cordoned", "4", unschedulable=True),
    node("not-ready", "8", ready=False),
]
CONFIGMAPS = {
    "linear": {"linear": json.dumps({"coresPerReplica": 2, "nodesPerReplica": 1, "min": 1, "max": 100})},
    "bad": {"linear": json.dumps({"min": 1})},
}
SCALES = {
    ("apps/v1", "deployments", "web"): 1,
    ("apps/v1", "replicasets", "db"): 5,
}
VERSION = [100]


def configmap(name, data):
    return {
        "kind": "ConfigMap",
        "apiVersion": "v1",
        "metadata": {"name": name, "namespace": "default", "resourceVersion": str(VERSION[0])},
        "data": data,
    }


def scale(group, resource, name, replicas):
    return {
        "kind": "Scale",
        "apiVersion": "autoscaling/v1",
        "metadata": {"name": name, "namespace": "default", "resourceVersion": str(VERSION[0])},
        "spec": {"replicas": replicas},
        "status": {"replicas": replicas},
    }


def status(code, reason):
    return {"kind": "Status", "apiVersion": "v1", "metadata": {}, "status": "Failure",
            "reason": reason, "code": code, "message": reason}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def record(self, obj=None):
        if obj is not None:
            obj = dict(obj, contentType=self.headers.get("Content-Type"))
        sys.stdout.write("REQ %s %s %s\n" % (self.command, self.path, json.dumps(obj) if obj else "-"))
        sys.stdout.flush()

    def reply(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorized(self):
        if self.headers.get("Authorization") != "Bearer verity-token":
            self.reply(401, status(401, "Unauthorized"))
            return False
        return True

    def body(self):
        return self.rfile.read(int(self.headers.get("Content-Length", "0")))

    def scale_key(self):
        parts = self.path.split("?")[0].strip("/").split("/")
        # apis/apps/v1/namespaces/default/<resource>/<name>/scale
        if len(parts) == 8 and parts[:2] == ["apis", "apps"] and parts[3:5] == ["namespaces", "default"] \
                and parts[7] == "scale":
            return ("apps/" + parts[2], parts[5], parts[6])
        return None

    def do_GET(self):
        self.record()
        if not self.authorized():
            return
        path = self.path.split("?")[0]
        if path == "/api/v1/nodes":
            if "watch=true" in self.path:
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.flush()
                time.sleep(3600)
                return
            return self.reply(200, {"kind": "NodeList", "apiVersion": "v1",
                                    "metadata": {"resourceVersion": "1"}, "items": NODES})
        prefix = "/api/v1/namespaces/default/configmaps/"
        if path.startswith(prefix):
            name = path[len(prefix):]
            with LOCK:
                if name in CONFIGMAPS:
                    return self.reply(200, configmap(name, CONFIGMAPS[name]))
            return self.reply(404, status(404, "NotFound"))
        key = self.scale_key()
        if key in SCALES:
            with LOCK:
                return self.reply(200, scale(*key, SCALES[key]))
        return self.reply(404, status(404, "NotFound"))

    def do_POST(self):
        obj = pb_decode(self.body())
        self.record(obj)
        if not self.authorized():
            return
        if self.path.split("?")[0] == "/api/v1/namespaces/default/configmaps":
            with LOCK:
                VERSION[0] += 1
                CONFIGMAPS[obj["metadata"]["name"]] = obj["data"]
                return self.reply(201, configmap(obj["metadata"]["name"], obj["data"]))
        return self.reply(404, status(404, "NotFound"))

    def do_PUT(self):
        obj = pb_decode(self.body())
        self.record(obj)
        if not self.authorized():
            return
        key = self.scale_key()
        if key in SCALES:
            with LOCK:
                VERSION[0] += 1
                SCALES[key] = obj["spec"]["replicas"]
                return self.reply(200, scale(*key, SCALES[key]))
        return self.reply(404, status(404, "NotFound"))


server = ThreadingHTTPServer(("0.0.0.0", 8443), Handler)
server.daemon_threads = True
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain("/pki/api.crt", "/pki/api.key")
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
PY
chmod -R a+rX "$work"

docker network create --internal "$network" >/dev/null
docker run -d --name "$api" --network "$network" --network-alias api --read-only \
  -v "$work/api.py:/api.py:ro" -v "$work/pki:/pki:ro" "$python" python -u /api.py >/dev/null
attempts=0
until docker exec "$api" python -c '
import ssl, urllib.request
ctx = ssl.create_default_context(cafile="/pki/ca.crt")
ctx.check_hostname = False
req = urllib.request.Request("https://127.0.0.1:8443/api/v1/nodes", headers={"Authorization": "Bearer verity-token"})
urllib.request.urlopen(req, context=ctx)' >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || { docker logs "$api" >&2; fail 'API fixture did not become ready'; }
  sleep 1
done

run_autoscaler() {
  name=$1
  shift
  docker run -d --name "$name" --network "$network" --network-alias "$name" --read-only \
    -e KUBERNETES_SERVICE_HOST=api -e KUBERNETES_SERVICE_PORT=8443 \
    -v "$work/sa:/var/run/secrets/kubernetes.io/serviceaccount:ro" \
    "$image" --namespace=default --poll-period-seconds=1 --logtostderr=true --v=2 "$@" >/dev/null ||
    fail "cannot start $name"
}

requests() {
  docker logs "$api" >"$work/requests" 2>&1
}

# wait_for_request NAME PATTERN: wait until the fixture saw a matching request.
wait_for_request() {
  attempts=0
  while :; do
    requests
    grep -E "$2" "$work/requests" >/dev/null && return 0
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 60 ]; then
      docker logs "$1" >&2 2>&1 || true
      cat "$work/requests" >&2
      fail "$1 never sent a request matching $2"
    fi
    sleep 1
  done
}

last_poll() {
  docker exec "$api" python -c '
import sys, urllib.error, urllib.request
try:
    r = urllib.request.urlopen("http://" + sys.argv[1] + ":8080/last-poll")
    print(("%d %s" % (r.status, r.read().decode())).strip())
except urllib.error.HTTPError as e:
    print(("%d %s" % (e.code, e.read().decode())).strip())' "$1"
}

# Linear mode: 2 schedulable nodes and 8 schedulable cores with coresPerReplica=2
# and nodesPerReplica=1 means max(ceil(8/2), ceil(2/1)) = 4 replicas. Counting
# the cordoned and NotReady nodes would give 10.
run_autoscaler "$suffix-linear" --configmap=linear --target=deployment/web
wait_for_request "$suffix-linear" '^REQ PUT /apis/apps/v1/namespaces/default/deployments/web/scale '
grep -E '^REQ PUT /apis/apps/v1/namespaces/default/deployments/web/scale ' "$work/requests" >"$work/linear-put"
test "$(wc -l <"$work/linear-put")" -eq 1 || fail "expected one scale update: $(cat "$work/linear-put")"
sed 's/^REQ PUT [^ ]* //' "$work/linear-put" | jq -e '.spec.replicas == 4 and .kind == "Scale" and
    .contentType == "application/vnd.kubernetes.protobuf"' >/dev/null ||
  fail "linear scale update did not set 4 replicas: $(cat "$work/linear-put")"
grep -E '^REQ GET /api/v1/namespaces/default/configmaps/linear ' "$work/requests" >/dev/null ||
  fail 'linear autoscaler did not read its ConfigMap'
docker logs "$suffix-linear" >"$work/linear.log" 2>&1
grep -F 'Cluster status: SchedulableNodes[2], TotalNodes[4], SchedulableCores[8], TotalCores[20]' \
  "$work/linear.log" >/dev/null || fail "unexpected cluster status: $(cat "$work/linear.log")"
grep -F 'Replicas are not as expected : updating deployment/web from 1 to 4' "$work/linear.log" \
  >/dev/null || fail "missing scaling decision log: $(cat "$work/linear.log")"

# Later poll cycles see the new replica count and leave the target alone.
before=$(grep -c '^REQ GET /apis/apps/v1/namespaces/default/deployments/web/scale ' "$work/requests")
attempts=0
while :; do
  requests
  after=$(grep -c '^REQ GET /apis/apps/v1/namespaces/default/deployments/web/scale ' "$work/requests")
  [ "$after" -ge $((before + 2)) ] && break
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || fail 'linear autoscaler stopped polling'
  sleep 1
done
test "$(grep -c '^REQ PUT /apis/apps/v1/namespaces/default/deployments/web/scale ' "$work/requests")" -eq 1 ||
  fail "a converged target was scaled again: $(cat "$work/requests")"
poll=$(last_poll "$suffix-linear")
test "$poll" = 200 || fail "healthy /last-poll returned: $poll"
if grep -E '^REQ (PUT|POST) /api/v1/namespaces/default/configmaps' "$work/requests" >/dev/null; then
  fail 'linear autoscaler wrote a ConfigMap'
fi
docker rm -f "$suffix-linear" >/dev/null

# Ladder mode from --default-params: the missing ConfigMap is created, then
# 8 schedulable cores map to 3 replicas and 2 nodes map to 2, so the
# replicaset is scaled from 5 down to 3.
run_autoscaler "$suffix-ladder" --configmap=ladder --target=replicaset/db \
  --default-params='{"ladder":{"coresToReplicas":[[1,1],[8,3],[64,5]],"nodesToReplicas":[[1,1],[2,2]]}}'
wait_for_request "$suffix-ladder" '^REQ PUT /apis/apps/v1/namespaces/default/replicasets/db/scale '
grep -E '^REQ POST /api/v1/namespaces/default/configmaps ' "$work/requests" >"$work/ladder-post" ||
  fail "ladder ConfigMap was not created: $(cat "$work/requests")"
sed 's/^REQ POST [^ ]* //' "$work/ladder-post" |
  jq -e '.kind == "ConfigMap" and .metadata.name == "ladder" and
    (.data.ladder | fromjson | .coresToReplicas[1] == [8,3])' \
    >/dev/null || fail "unexpected created ConfigMap: $(cat "$work/ladder-post")"
grep -E '^REQ PUT /apis/apps/v1/namespaces/default/replicasets/db/scale ' "$work/requests" |
  sed 's/^REQ PUT [^ ]* //' | jq -e '.spec.replicas == 3' >/dev/null ||
  fail "ladder scale update did not set 3 replicas: $(cat "$work/requests")"
docker logs "$suffix-ladder" >"$work/ladder.log" 2>&1
grep -F 'updating replicaset/db from 5 to 3' "$work/ladder.log" >/dev/null ||
  fail "missing ladder scaling decision: $(cat "$work/ladder.log")"
docker rm -f "$suffix-ladder" >/dev/null

# Invalid params are rejected: no scale write happens and /last-poll reports the error.
run_autoscaler "$suffix-bad" --configmap=bad --target=deployment/web
wait_for_request "$suffix-bad" '^REQ GET /api/v1/namespaces/default/configmaps/bad '
attempts=0
until poll=$(last_poll "$suffix-bad") && case $poll in 500*) true ;; *) false ;; esac; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || fail "/last-poll did not report the invalid params: $poll"
  sleep 1
done
case $poll in
  *'should at least provide either CoresPerReplica or NodesPerReplica'*) ;;
  *) fail "unexpected /last-poll error: $poll" ;;
esac
requests
test "$(grep -c '^REQ PUT ' "$work/requests")" -eq 2 ||
  fail "invalid params caused a scale write: $(cat "$work/requests")"

printf 'SMOKE PASS version=%s\n' "$version"
