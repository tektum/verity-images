#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
version=$(sed -n 's/^  version: "\([0-9][0-9.]*\)".*/\1/p' "$here/../melange.yaml")
# Catalog Python, pinned by index digest, serves a fake ECR API on loopback.
python_index=ghcr.io/tektum/python@sha256:d059268a2e4f0ef0cc82bb50c847e69e16e174736758013a153cb36311fa6dd6
fake="verity-ecr-cp-fake-$$"
work=$(mktemp -d)
api=credentialprovider.kubelet.k8s.io/v1
ecr_image=123456789012.dkr.ecr.us-west-2.amazonaws.com/team/app:1.0

# AWS documentation example keys. Every run has no network route (--network
# none, or the loopback-only namespace of a --network none container), so
# nothing can reach AWS whatever the credentials are.
key_id=AKIAIOSFODNN7EXAMPLE
secret=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  docker rm -f "$fake" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail 'could not read the pinned cloud-provider-aws version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/ecr-credential-provider"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'

# Kubelet exec plugin: request on stdin, response on stdout, no network, no
# AWS credentials, IMDS disabled, read-only root, no capabilities.
plugin() {
  docker run -i --rm --network none --read-only --cap-drop=ALL \
    -e AWS_EC2_METADATA_DISABLED=true "$image" "$@"
}

request() {
  printf '{"apiVersion":"%s","kind":"%s","image":"%s"}' "$1" "$2" "$3"
}

# expect_error NAME STDIN DIAGNOSTIC: non-zero exit, nothing on stdout (kubelet
# parses stdout as the response), and the expected diagnostic on stderr.
expect_error() {
  name=$1
  status=0
  printf '%s' "$2" | plugin get-credentials >"$work/$name.out" 2>"$work/$name.err" || status=$?
  test "$status" -ne 0 || fail "$name: plugin exited 0: $(cat "$work/$name.out")"
  test ! -s "$work/$name.out" || fail "$name: plugin wrote a response: $(cat "$work/$name.out")"
  grep -F -- "$3" "$work/$name.err" >/dev/null || fail "$name: missing '$3': $(cat "$work/$name.err")"
}

plugin --version >"$work/version" 2>&1 || fail "--version failed: $(cat "$work/version")"
grep -Fx "ecr-credential-provider version v$version" "$work/version" >/dev/null ||
  fail "version is not v$version: $(cat "$work/version")"

status=0
plugin --definitely-invalid >"$work/flag" 2>&1 || status=$?
test "$status" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'unknown flag: --definitely-invalid' "$work/flag" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/flag")"

# Malformed and unsupported requests are rejected before any AWS call.
expect_error empty '' 'json parse error: unexpected end of JSON input'
expect_error garbage 'not json' 'json parse error'
expect_error no-image "$(request "$api" CredentialProviderRequest '')" \
  'image in plugin request was empty'
expect_error bad-kind "$(request "$api" Bogus "$ecr_image")" 'no kind "Bogus" is registered'
expect_error v1alpha1 "$(request credentialprovider.kubelet.k8s.io/v1alpha1 CredentialProviderRequest "$ecr_image")" \
  'group version credentialprovider.kubelet.k8s.io/v1alpha1 is not supported'
expect_error bad-group "$(request example.com/v1 CredentialProviderRequest "$ecr_image")" \
  'group version example.com/v1 is not supported'

# The plugin does not filter images itself: kubelet's matchImages does. A
# non-ECR image is still sent to ECR, and without credentials it fails cleanly
# with no response and no IMDS fallback.
expect_error non-ecr "$(request "$api" CredentialProviderRequest docker.io/library/nginx:latest)" \
  'get credentials: failed to refresh cached credentials'
grep -F 'access disabled to EC2 IMDS' "$work/non-ecr.err" >/dev/null ||
  fail "non-ECR request did not stop at disabled IMDS: $(cat "$work/non-ecr.err")"
expect_error ecr-no-creds "$(request "$api" CredentialProviderRequest "$ecr_image")" \
  'operation error ECR: GetAuthorizationToken'

# Full exec protocol against a loopback fake ECR API.
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

cat >"$work/fake.py" <<'EOF'
import base64, http.server, json, re, sys

class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        scope = re.search(r"Credential=[^/]+/\d+/([^/]+)/([^/]+)/", self.headers.get("Authorization", ""))
        target = self.headers.get("X-Amz-Target", "")
        print("CALL", target, *(scope.groups() if scope else ("-", "-")), flush=True)
        if target != "AmazonEC2ContainerRegistry_V20150921.GetAuthorizationToken":
            self.send_response(400); self.end_headers(); return
        body = json.dumps({"authorizationData": [{
            "authorizationToken": base64.b64encode(b"AWS:verity-ecr-password").decode(),
            "expiresAt": 4102444800,
            "proxyEndpoint": "https://123456789012.dkr.ecr.us-west-2.amazonaws.com"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/x-amz-json-1.1")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass

http.server.HTTPServer(("127.0.0.1", 8080), H).serve_forever()
EOF
chmod 644 "$work/fake.py"
docker run -d --name "$fake" --network none -v "$work/fake.py:/fake.py:ro" \
  --entrypoint python "$python_image" -u /fake.py >/dev/null || fail 'fake ECR did not start'
ready=0
for _ in $(seq 1 30); do
  if docker exec "$fake" python -c 'import socket; socket.create_connection(("127.0.0.1", 8080), 1)' 2>/dev/null; then
    ready=1
    break
  fi
  sleep 1
done
[ "$ready" = 1 ] || fail "fake ECR not ready: $(docker logs "$fake" 2>&1)"

fake_plugin() {
  docker run -i --rm --network "container:$fake" --read-only --cap-drop=ALL \
    -e AWS_EC2_METADATA_DISABLED=true -e AWS_ACCESS_KEY_ID="$key_id" \
    -e AWS_SECRET_ACCESS_KEY="$secret" -e AWS_ENDPOINT_URL_ECR=http://127.0.0.1:8080 \
    "$image" get-credentials
}

request "$api" CredentialProviderRequest "$ecr_image" | fake_plugin >"$work/resp" 2>"$work/resp.err" ||
  fail "get-credentials against fake ECR failed: $(cat "$work/resp.err")"
docker run --rm --network none -v "$work/resp:/resp:ro" --entrypoint python "$python_image" -c '
import json, sys
r = json.load(open("/resp"))
assert r["apiVersion"] == "credentialprovider.kubelet.k8s.io/v1", r
assert r["kind"] == "CredentialProviderResponse", r
assert r["cacheKeyType"] == "Registry", r
assert r.get("cacheDuration"), r
auth = r["auth"]
assert list(auth) == ["123456789012.dkr.ecr.us-west-2.amazonaws.com"], auth
entry = auth["123456789012.dkr.ecr.us-west-2.amazonaws.com"]
assert entry == {"username": "AWS", "password": "verity-ecr-password"}, entry
' || fail "unexpected CredentialProviderResponse: $(cat "$work/resp")"

# The region is parsed from the image host and signs the ECR request.
docker logs "$fake" >"$work/calls" 2>&1
grep -Fx 'CALL AmazonEC2ContainerRegistry_V20150921.GetAuthorizationToken us-west-2 ecr' "$work/calls" >/dev/null ||
  fail "fake ECR did not see a us-west-2 GetAuthorizationToken call: $(cat "$work/calls")"
test "$(grep -c '^CALL ' "$work/calls")" -eq 1 || fail "unexpected ECR calls: $(cat "$work/calls")"

printf 'ecr-credential-provider %s exec protocol checks passed\n' "$version"
