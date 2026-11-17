#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
# Catalog Python 3.13, pinned by index digest, runs the echo server, the client
# and the offline SigV4 verifier.
python_index=ghcr.io/tektum/python@sha256:d059268a2e4f0ef0cc82bb50c847e69e16e174736758013a153cb36311fa6dd6
suffix="verity-sigv4-$$"
net="$suffix-net"
echo_name="$suffix-echo"
proxy_a="$suffix-a"
proxy_b="$suffix-b"
work=$(mktemp -d)

# AWS documentation example keys and a fake session token. Every container
# below runs on an --internal network (or --network none), so nothing can
# reach AWS whatever the credentials are.
key_id=AKIAIOSFODNN7EXAMPLE
secret=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
token=VerityFakeSessionToken/2026+smoke=

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  docker rm -f "$echo_name" "$proxy_a" "$proxy_b" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

# Upstream contract: FROM scratch, root, ENTRYPOINT ["./aws-sigv4-proxy"]
# from /, no CMD, CA bundle at /etc/ssl/certs/ca-certificates.crt.
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 0 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/aws-sigv4-proxy"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = / ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt >/dev/null ||
  fail 'SSL_CERT_FILE does not point at the CA bundle'

mkdir -p "$work/cfg" "$work/log"
chmod 755 "$work/cfg"
chmod 777 "$work/log"

offline() {
  docker run --rm --network none --read-only --cap-drop=ALL "$@"
}

# The upstream /aws-sigv4-proxy path still starts the same binary.
offline --entrypoint /aws-sigv4-proxy "$image" --help >"$work/help" 2>&1 ||
  fail "--help through /aws-sigv4-proxy failed: $(cat "$work/help")"
for flag in --port --host --sign-host --name --region --role-arn --upstream-url-scheme \
  --unsigned-payload --strip; do
  grep -F -- "$flag" "$work/help" >/dev/null || fail "--help does not list $flag"
done

status=0
offline "$image" --definitely-invalid >"$work/invalid" 2>&1 || status=$?
test "$status" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'unknown long flag' "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"

# Echo server: records every request (method, target, headers, body) as one
# JSON line and answers with a small JSON document.
cat >"$work/cfg/echo.py" <<'EOF'
import base64
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def handle_any(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        record = {
            "method": self.command,
            "target": self.path,
            "headers": [[k, v] for k, v in self.headers.items()],
            "body": base64.b64encode(body).decode(),
        }
        with open(sys.argv[2], "a", encoding="utf-8") as log:
            log.write(json.dumps(record) + "\n")
        payload = json.dumps({"echo": "verity", "method": self.command, "target": self.path}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    do_GET = do_POST = do_PUT = handle_any

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("0.0.0.0", int(sys.argv[1])), Handler).serve_forever()
EOF

# Client: one request through a proxy, retried until the proxy listens.
# Prints {"status", "body"} as JSON.
cat >"$work/cfg/client.py" <<'EOF'
import json
import sys
import time
import urllib.error
import urllib.request

url, host, method, body = sys.argv[1:5]
data = body.encode() if body else None
deadline = time.monotonic() + 30
while True:
    request = urllib.request.Request(url, data=data, method=method)
    if host != "-":
        request.add_header("Host", host)
    request.add_header("X-Verity-Client", "smoke")
    if data is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            status, payload = response.status, response.read()
        break
    except urllib.error.HTTPError as error:
        status, payload = error.code, error.read()
        break
    except OSError:
        if time.monotonic() > deadline:
            raise
        time.sleep(0.5)
print(json.dumps({"status": status, "body": payload.decode("utf-8", "replace")}))
EOF

# Verifier: checks the recorded request's SigV4 headers and recomputes the
# signature from the recorded method, target, headers and body with the
# secret key. The canonicalization is self-checked first against the AWS
# documentation example (IAM ListUsers, 20150830T123600Z).
cat >"$work/cfg/verify.py" <<'EOF'
import base64
import datetime
import hashlib
import hmac
import json
import re
import sys
from urllib.parse import parse_qsl, quote, urlsplit

AUTH = re.compile(
    r"AWS4-HMAC-SHA256 Credential=(?P<key>[A-Z0-9]+)/(?P<date>[0-9]{8})/(?P<region>[a-z0-9-]+)/"
    r"(?P<service>[a-z0-9-]+)/aws4_request, SignedHeaders=(?P<signed>[a-z0-9;-]+), "
    r"Signature=(?P<signature>[0-9a-f]{64})"
)


def fail(message):
    print(f"verify: {message}", file=sys.stderr)
    sys.exit(1)


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


def hmac_sha256(key, message):
    return hmac.new(key, message.encode(), hashlib.sha256).digest()


def canonical_query(query):
    pairs = sorted(parse_qsl(query, keep_blank_values=True), key=lambda pair: pair[0])
    return "&".join(f"{quote(k, safe='-_.~')}={quote(v, safe='-_.~')}" for k, v in pairs)


def signature(secret, method, path, query, headers, signed, body, amz_date, region, service):
    canonical_headers = "".join(
        f"{name}:{','.join(v.strip() for v in headers[name])}\n" for name in signed.split(";")
    )
    canonical_request = "\n".join([
        method,
        quote(path, safe="/-_.~"),
        canonical_query(query),
        canonical_headers,
        signed,
        sha256_hex(body),
    ])
    scope = f"{amz_date[:8]}/{region}/{service}/aws4_request"
    string_to_sign = "\n".join(
        ["AWS4-HMAC-SHA256", amz_date, scope, sha256_hex(canonical_request.encode())]
    )
    key = ("AWS4" + secret).encode()
    for part in (amz_date[:8], region, service, "aws4_request"):
        key = hmac_sha256(key, part)
    return hmac.new(key, string_to_sign.encode(), hashlib.sha256).hexdigest()


known = signature(
    "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", "GET", "/", "Action=ListUsers&Version=2010-05-08",
    {
        "content-type": ["application/x-www-form-urlencoded; charset=utf-8"],
        "host": ["iam.amazonaws.com"],
        "x-amz-date": ["20150830T123600Z"],
    },
    "content-type;host;x-amz-date", b"", "20150830T123600Z", "us-east-1", "iam",
)
if known != "5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7":
    fail(f"verifier does not reproduce the AWS documentation example: {known}")

log, index, secret, key_id, region, service, token, signed_expected = sys.argv[1:9]
records = [json.loads(line) for line in open(log, encoding="utf-8") if line.strip()]
record = records[int(index)]
headers = {}
for name, value in record["headers"]:
    headers.setdefault(name.lower(), []).append(value)


def one(name):
    values = headers.get(name, [])
    if len(values) != 1:
        fail(f"expected one {name} header, got {values!r}")
    return values[0]


authorization = one("authorization")
match = AUTH.fullmatch(authorization)
if not match:
    fail(f"malformed Authorization header: {authorization!r}")
amz_date = one("x-amz-date")
if not re.fullmatch(r"[0-9]{8}T[0-9]{6}Z", amz_date):
    fail(f"malformed X-Amz-Date: {amz_date!r}")
signed_at = datetime.datetime.strptime(amz_date, "%Y%m%dT%H%M%SZ").replace(tzinfo=datetime.timezone.utc)
skew = abs((datetime.datetime.now(datetime.timezone.utc) - signed_at).total_seconds())
if skew > 900:
    fail(f"X-Amz-Date {amz_date} is {skew:.0f}s away from now")
for field, want in (("key", key_id), ("date", amz_date[:8]), ("region", region), ("service", service)):
    if match[field] != want:
        fail(f"credential {field} is {match[field]!r}, want {want!r}")
signed = match["signed"]
names = signed.split(";")
if names != sorted(names) or "host" not in names or "x-amz-date" not in names:
    fail(f"SignedHeaders is not a sorted list with host and x-amz-date: {signed!r}")
if "authorization" in names or "x-verity-client" in names:
    fail(f"SignedHeaders covers headers added outside the signer: {signed!r}")
if signed_expected != "-" and signed != signed_expected:
    fail(f"SignedHeaders is {signed!r}, want {signed_expected!r}")
if token:
    if one("x-amz-security-token") != token:
        fail("X-Amz-Security-Token does not carry the session token")
    if "x-amz-security-token" not in names:
        fail(f"X-Amz-Security-Token is not signed: {signed!r}")
elif "x-amz-security-token" in headers:
    fail("X-Amz-Security-Token sent without a session token")
for name in names:
    if name not in headers:
        fail(f"signed header {name} was not received")

target = urlsplit(record["target"])
body = base64.b64decode(record["body"])
args = (record["method"], target.path, target.query, headers, signed, body, amz_date, match["region"],
        match["service"])
expected = signature(secret, *args)
if expected != match["signature"]:
    fail(f"signature {match['signature']} does not match recomputed {expected}")
if signature(secret + "x", *args) == match["signature"]:
    fail("signature does not depend on the secret key")
print(json.dumps({
    "method": record["method"],
    "target": record["target"],
    "host": one("host"),
    "client": headers.get("x-verity-client", []),
    "body": body.decode(),
    "signed": signed,
    "scope": f"{match['date']}/{match['region']}/{match['service']}",
}))
EOF
chmod 644 "$work/cfg/"*

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

# Internal network: containers reach each other by name, nothing reaches out.
docker network create --internal "$net" >/dev/null || fail 'could not create the internal network'
test "$(docker network inspect --format '{{.Internal}}' "$net")" = true ||
  fail 'test network is not internal'

docker run -d --name "$echo_name" --network "$net" --network-alias echo --read-only \
  --cap-drop=ALL --user 65532:65532 -v "$work/cfg:/cfg:ro" -v "$work/log:/log" \
  "$python_image" /cfg/echo.py 8080 /log/requests.jsonl >/dev/null ||
  fail 'could not start the echo server'
i=0
until docker exec "$echo_name" python3 -c \
  'import socket; socket.create_connection(("127.0.0.1", 8080), 1).close()' >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -le 30 ] || fail "echo server did not listen: $(docker logs "$echo_name" 2>&1)"
  sleep 1
done

# Proxy A: default image user, explicit signing overrides and a session token.
# AWS_REGION is overridden by --region; the request is sent to the echo server
# over plain HTTP while the Host header and the signature name the sign-host.
docker run -d --name "$proxy_a" --network "$net" --read-only --cap-drop=ALL \
  -e AWS_ACCESS_KEY_ID="$key_id" -e AWS_SECRET_ACCESS_KEY="$secret" \
  -e AWS_SESSION_TOKEN="$token" -e AWS_REGION=us-east-2 -e AWS_EC2_METADATA_DISABLED=true \
  "$image" --name execute-api --region eu-west-3 --sign-host api.verity.example \
  --host echo:8080 --upstream-url-scheme http >/dev/null || fail 'could not start proxy A'

# Proxy B: arbitrary non-root user, no session token and no signing overrides,
# so the service and region come from the incoming AWS Host header.
docker run -d --name "$proxy_b" --network "$net" --read-only --cap-drop=ALL --user 65532:65532 \
  -e AWS_ACCESS_KEY_ID="$key_id" -e AWS_SECRET_ACCESS_KEY="$secret" -e AWS_REGION=us-east-2 \
  -e AWS_EC2_METADATA_DISABLED=true \
  "$image" --port :9090 --host echo:8080 --upstream-url-scheme http >/dev/null ||
  fail 'could not start proxy B'

client() {
  out=$1
  shift
  timeout 60 docker run --rm --network "$net" --read-only --cap-drop=ALL --user 65532:65532 \
    -v "$work/cfg:/cfg:ro" "$python_image" /cfg/client.py "$@" >"$work/$out" 2>&1 ||
    fail "client $out failed: $(cat "$work/$out")
proxy A: $(docker logs "$proxy_a" 2>&1)
proxy B: $(docker logs "$proxy_b" 2>&1)"
}
# verify OUT INDEX REGION SERVICE TOKEN SIGNED_HEADERS: check request INDEX of
# the echo log, signed with the fake key for REGION and SERVICE. An empty
# TOKEN expects no security token; SIGNED_HEADERS "-" accepts any valid list.
verify() {
  out=$1
  shift
  offline --user 65532:65532 -v "$work/cfg:/cfg:ro" -v "$work/log:/log:ro" "$python_image" \
    /cfg/verify.py /log/requests.jsonl "$1" "$secret" "$key_id" "$2" "$3" "$4" "$5" >"$work/$out" 2>&1 ||
    fail "signature check $out failed: $(cat "$work/$out")"
}
records() {
  if [ -f "$work/log/requests.jsonl" ]; then
    wc -l <"$work/log/requests.jsonl" | tr -d ' '
  else
    echo 0
  fi
}
field() {
  jq -r "$2" "$work/$1"
}

body='{"verity":"sigv4"}'
client a.json "http://$proxy_a:8080/verity/items?space=x%20y&b=2&a=1" - POST "$body"
test "$(field a.json .status)" = 200 || fail "proxy A answered: $(cat "$work/a.json")"
test "$(field a.json '.body | fromjson | .echo')" = verity ||
  fail "proxy A did not relay the echo response: $(cat "$work/a.json")"
test "$(records)" = 1 || fail "echo server saw $(records) requests after proxy A"
verify a.verify 0 eu-west-3 execute-api "$token" 'host;x-amz-date;x-amz-security-token'
test "$(field a.verify .method)" = POST || fail "unexpected method: $(cat "$work/a.verify")"
# The signer rewrites the query into canonical (sorted, %20) form.
test "$(field a.verify .target)" = '/verity/items?a=1&b=2&space=x%20y' ||
  fail "unexpected upstream target: $(cat "$work/a.verify")"
test "$(field a.verify .host)" = api.verity.example ||
  fail "Host is not the sign-host: $(cat "$work/a.verify")"
test "$(field a.verify .body)" = "$body" || fail "body changed in transit: $(cat "$work/a.verify")"
test "$(field a.verify '.client | join(",")')" = smoke ||
  fail "client header was not forwarded once: $(cat "$work/a.verify")"

client b.json "http://$proxy_b:9090/api/v1/query?query=up" aps-workspaces.us-west-2.amazonaws.com GET ''
test "$(field b.json .status)" = 200 || fail "proxy B answered: $(cat "$work/b.json")"
test "$(records)" = 2 || fail "echo server saw $(records) requests after proxy B"
verify b.verify 1 us-west-2 aps '' 'host;x-amz-date'
test "$(field b.verify .host)" = echo:8080 || fail "unexpected upstream Host: $(cat "$work/b.verify")"
test "$(field b.verify .target)" = '/api/v1/query?query=up' ||
  fail "unexpected upstream target: $(cat "$work/b.verify")"

# Negative: a non-AWS Host without overrides cannot be signed and is refused
# before anything is sent upstream.
client c.json "http://$proxy_b:9090/" verity.invalid GET ''
test "$(field c.json .status)" = 502 || fail "unsignable host was not refused: $(cat "$work/c.json")"
field c.json .body | grep -F 'unable to determine service from host: verity.invalid' >/dev/null ||
  fail "unsignable host diagnostic is missing: $(cat "$work/c.json")"
test "$(records)" = 2 || fail 'unsignable request reached the echo server'

echo 'SMOKE PASS'
