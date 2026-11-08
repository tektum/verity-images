#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
server_pid=

cleanup() {
  [ -z "$server_pid" ] || kill "$server_pid" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

# Minimal S3 fixture: ListBuckets succeeds only for the expected SigV4 access key.
cat >"$work/server.py" <<'PY'
import http.server
import sys

BODY = (
    b'<?xml version="1.0" encoding="UTF-8"?>'
    b'<ListAllMyBucketsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
    b'<Owner><ID>verity</ID><DisplayName>verity</DisplayName></Owner>'
    b'<Buckets><Bucket><Name>verity-smoke-bucket</Name>'
    b'<CreationDate>2026-01-01T00:00:00.000Z</CreationDate></Bucket></Buckets>'
    b'</ListAllMyBucketsResult>'
)
DENIED = (
    b'<?xml version="1.0" encoding="UTF-8"?>'
    b'<Error><Code>InvalidAccessKeyId</Code><Message>unknown access key</Message></Error>'
)


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        ok = "Credential=verity-access-key/" in self.headers.get("Authorization", "")
        self.send_response(200 if ok else 403)
        self.send_header("Content-Type", "application/xml")
        body = BODY if ok else DENIED
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w", encoding="ascii") as port_file:
    port_file.write(str(server.server_port))
server.serve_forever()
PY

[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/aws"]' ] \
  || fail 'unexpected image entrypoint'
case $(docker image inspect --format '{{json .Config.Cmd}}' "$image") in
  null|'[]') ;;
  *) fail 'unexpected image command' ;;
esac
[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected image user'

docker run --rm --network none "$image" --version | grep -Eq '^aws-cli/2\.' \
  || fail 'unexpected aws-cli version'

python3 "$work/server.py" "$work/port" &
server_pid=$!
attempts=0
until [ -s "$work/port" ]; do
  kill -0 "$server_pid" || fail 'S3 fixture exited early'
  attempts=$((attempts + 1))
  [ "$attempts" -lt 20 ] || fail 'S3 fixture did not start'
  sleep 1
done
port=$(cat "$work/port")

s3() {
  key=$1
  shift
  docker run --rm --network host --read-only --tmpfs /tmp --tmpfs /home/nonroot:uid=65532,gid=65532 \
    -e AWS_ACCESS_KEY_ID="$key" -e AWS_SECRET_ACCESS_KEY=verity-secret-key \
    -e AWS_DEFAULT_REGION=us-east-1 -e AWS_EC2_METADATA_DISABLED=true \
    "$image" --endpoint-url "http://127.0.0.1:$port" s3 ls "$@"
}

s3 verity-access-key | grep -Fq verity-smoke-bucket || fail 'bucket listing did not contain the bucket'

if output=$(s3 wrong-access-key 2>&1); then
  fail 'listing with an unknown access key succeeded'
fi
printf '%s\n' "$output" | grep -Fq InvalidAccessKeyId || fail 'unknown access key failed without the S3 error'

if docker run --rm --network none "$image" --endpoint-url http://127.0.0.1:1 s3 ls >/dev/null 2>&1; then
  fail 'listing without credentials or connectivity succeeded'
fi

printf 'SMOKE PASS image=%s\n' "$image"
