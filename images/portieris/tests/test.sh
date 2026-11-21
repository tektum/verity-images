#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# The catalog python image runs a stub Kubernetes API that serves Portieris
# policy lists; the pinned index is resolved per platform.
python_index=ghcr.io/tektum/python@sha256:d059268a2e4f0ef0cc82bb50c847e69e16e174736758013a153cb36311fa6dd6
label=verity.test=portieris-$$
network="verity-portieris-network-$$"
api="verity-portieris-api-$$"
server="verity-portieris-server-$$"
work=$(mktemp -d)

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -fv >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  docker logs "$api" >&2 2>/dev/null || true
  docker logs "$server" >&2 2>/dev/null || true
  printf '%s\n' "$1" >&2
  exit 1
}

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/portieris"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = \
  '["--alsologtostderr","-v=4"]' || fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /run ||
  fail 'unexpected working directory'

# Upstream image contract: the binary is also reachable at /portieris.
docker run --rm --network none --read-only --entrypoint /portieris "$image" --help \
  >"$work/help" 2>&1 || true
grep -F -- '-kubeconfig' "$work/help" >/dev/null || fail 'help does not list -kubeconfig'

# Negative: outside a cluster and without a kubeconfig the webhook exits non-zero
# with the in-cluster configuration error. glog also writes log files to /tmp.
if docker run --rm --network none --read-only --tmpfs /tmp "$image" \
  >"$work/no-cluster" 2>&1; then
  fail 'webhook started without a cluster configuration'
fi
grep -F 'unable to load in-cluster configuration' "$work/no-cluster" >/dev/null ||
  fail 'missing in-cluster configuration diagnostic'

# Serving certificate, mounted where the Helm chart mounts its secret.
mkdir -p "$work/certs" "$work/api" "$work/log"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=portieris \
  -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' \
  -keyout "$work/certs/tls.key" -out "$work/certs/tls.crt" >/dev/null 2>&1 ||
  fail 'cannot create the serving certificate'
cat >"$work/certs/kubeconfig" <<'EOF'
apiVersion: v1
kind: Config
clusters:
  - name: stub
    cluster:
      server: http://api:8080
users:
  - name: smoke
    user:
      token: smoke
contexts:
  - name: stub
    context:
      cluster: stub
      user: smoke
current-context: stub
EOF
cp "$here/fake_api.py" "$work/api/fake_api.py"
: >"$work/log/requests"
chmod 0644 "$work/certs/"* "$work/api/fake_api.py"
chmod 0666 "$work/log/requests"
chmod 0777 "$work/log"

# pull_child INDEX: pull the pinned index by its per-platform child digest,
# verifying the index bytes against the pin first so the pin stays authoritative.
image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
pull_child() {
  raw=$(docker buildx imagetools inspect --raw "$1") || fail "cannot inspect $1"
  [ "sha256:$(printf '%s' "$raw" | sha256sum | cut -d' ' -f1)" = "${1#*@}" ] ||
    fail "index digest mismatch for $1"
  child=$(printf '%s' "$raw" | jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') || fail "cannot resolve a child of $1"
  case $child in
    sha256:*) ;;
    *) fail "no unique linux/$image_arch child in $1" ;;
  esac
  docker pull --quiet --platform "linux/$image_arch" "${1%%@*}@$child" >/dev/null ||
    fail "cannot pull ${1%%@*}@$child"
  printf '%s' "${1%%@*}@$child"
}
python_image=$(pull_child "$python_index")

docker network create --label "$label" "$network" >/dev/null
docker run -d --label "$label" --name "$api" --network "$network" --network-alias api \
  --user 65532:65532 -v "$work/api:/stub:ro" -v "$work/log:/log" \
  "$python_image" /stub/fake_api.py 8080 /log/requests >/dev/null
attempts=0
until docker exec "$api" python3 -c \
  'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8080/healthz", timeout=1)' \
  >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || fail 'stub API did not start'
  sleep 1
done

docker run -d --label "$label" --name "$server" --network "$network" --read-only \
  --tmpfs /tmp --tmpfs /run:uid=65532,gid=0,mode=0775 \
  -p 127.0.0.1::8000 -p 127.0.0.1::8080 -v "$work/certs:/etc/certs:ro" \
  "$image" --alsologtostderr -v=4 --kubeconfig=/etc/certs/kubeconfig >/dev/null
webhook_port=$(docker port "$server" 8000/tcp | head -n 1 | sed 's/.*://')
metrics_port=$(docker port "$server" 8080/tcp | head -n 1 | sed 's/.*://')
[ -n "$webhook_port" ] && [ -n "$metrics_port" ] || fail 'ports are not published'

attempts=0
until curl --fail --silent --insecure --connect-timeout 1 --max-time 5 \
  "https://127.0.0.1:$webhook_port/health/readiness" >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || fail 'webhook did not become ready'
  sleep 1
done
curl --fail --silent --insecure --max-time 5 \
  "https://127.0.0.1:$webhook_port/health/liveness" >/dev/null || fail 'liveness probe failed'
docker logs "$server" 2>&1 | grep -F "Starting portieris v$expected_version" >/dev/null ||
  fail "startup log does not report v$expected_version"

# The webhook serves TLS only.
if curl --silent --max-time 5 "http://127.0.0.1:$webhook_port/health/liveness" \
  -o /dev/null -w '%{http_code}' 2>/dev/null | grep -Fx 200 >/dev/null; then
  fail 'webhook answered plain HTTP'
fi

# admit NAMESPACE IMAGE OUT: send a Pod CREATE AdmissionReview, keep the response.
admit() {
  uid=$(cat /proc/sys/kernel/random/uuid)
  jq -n --arg uid "$uid" --arg ns "$1" --arg image "$2" '{
    apiVersion: "admission.k8s.io/v1", kind: "AdmissionReview",
    request: {
      uid: $uid, operation: "CREATE", namespace: $ns,
      kind: {group: "", version: "v1", kind: "Pod"},
      resource: {group: "", version: "v1", resource: "pods"},
      userInfo: {username: "smoke"},
      object: {apiVersion: "v1", kind: "Pod",
        metadata: {name: "smoke", namespace: $ns},
        spec: {containers: [{name: "app", image: $image}]}}
    }}' >"$work/review.json"
  curl --fail --silent --insecure --max-time 30 -X POST \
    -H 'Content-Type: application/json' --data-binary "@$work/review.json" \
    "https://127.0.0.1:$webhook_port/admit" >"$3" || fail "admission request failed for $2"
  jq -e --arg uid "$uid" '.response.uid == $uid' "$3" >/dev/null ||
    fail "admission response does not echo the request uid for $2"
}

admit trusted registry.example/allowed/app:1.0 "$work/allowed.json"
jq -e '.response.allowed == true' "$work/allowed.json" >/dev/null ||
  fail "matching ImagePolicy was not allowed: $(cat "$work/allowed.json")"

admit trusted registry.example/other/app:1.0 "$work/unmatched.json"
jq -e '.response.allowed == false and
  (.response.status.message | contains("no matching repositories in the ImagePolicies"))' \
  "$work/unmatched.json" >/dev/null ||
  fail "unmatched image was not denied: $(cat "$work/unmatched.json")"

admit default registry.example/allowed/app:1.0 "$work/no-policy.json"
jq -e '.response.allowed == false and
  (.response.status.message | contains("no image policies or cluster polices"))' \
  "$work/no-policy.json" >/dev/null ||
  fail "namespace without policies was not denied: $(cat "$work/no-policy.json")"

grep -Fx /apis/portieris.cloud.ibm.com/v1/namespaces/trusted/imagepolicies \
  "$work/log/requests" >/dev/null || fail 'webhook did not read namespace ImagePolicies'
grep -Fx /apis/portieris.cloud.ibm.com/v1/clusterimagepolicies "$work/log/requests" \
  >/dev/null || fail 'webhook did not fall back to ClusterImagePolicies'

curl --fail --silent --max-time 5 "http://127.0.0.1:$metrics_port/metrics" >"$work/metrics" ||
  fail 'metrics endpoint failed'
grep -Fx 'portieris_pod_admission_decision_allow_count 1' "$work/metrics" >/dev/null ||
  fail 'allow decision was not counted'
grep -Fx 'portieris_pod_admission_decision_deny_count 2' "$work/metrics" >/dev/null ||
  fail 'deny decisions were not counted'

# Fail closed: with the API gone, admission is denied rather than allowed.
docker rm -f "$api" >/dev/null
admit trusted registry.example/allowed/app:1.0 "$work/api-down.json"
jq -e '.response.allowed == false' "$work/api-down.json" >/dev/null ||
  fail "admission was allowed without the API: $(cat "$work/api-down.json")"

test "$(docker inspect --format '{{.State.Running}}' "$server")" = true ||
  fail 'webhook exited during the admission checks'

echo "portieris $expected_version smoke test passed"
