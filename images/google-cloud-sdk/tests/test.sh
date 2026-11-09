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

# Minimal Cloud Storage JSON API fixture: bucket listing succeeds only for the expected bearer token.
cat >"$work/server.py" <<'PY'
import http.server
import json
import sys

BUCKETS = json.dumps({
    "kind": "storage#buckets",
    "items": [{"kind": "storage#bucket", "id": "verity-smoke-bucket", "name": "verity-smoke-bucket"}],
}).encode()
DENIED = json.dumps({"error": {"code": 401, "message": "verity invalid credentials"}}).encode()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        ok = self.headers.get("Authorization") == "Bearer verity-token"
        listing = self.path.startswith("/storage/v1/b?")
        code, body = (200, BUCKETS) if ok and listing else (401 if not ok else 404, DENIED)
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w", encoding="ascii") as port_file:
    port_file.write(str(server.server_port))
server.serve_forever()
PY

[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/gcloud"]' ] \
  || fail 'unexpected image entrypoint'
case $(docker image inspect --format '{{json .Config.Cmd}}' "$image") in
  null|'[]') ;;
  *) fail 'unexpected image command' ;;
esac
[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected image user'

# Read-only root with only /tmp and the home directory writable, no network.
offline() {
  docker run --rm --network none --read-only --tmpfs /tmp --tmpfs /home/nonroot:uid=65532,gid=65532 \
    -e CLOUDSDK_CORE_DISABLE_USAGE_REPORTING=true "$@"
}

version=$(offline "$image" version) || fail 'gcloud version failed'
printf '%s\n' "$version" | grep -Eq '^Google Cloud SDK [0-9]+\.[0-9]+\.[0-9]+' \
  || fail 'unexpected gcloud version output'

gsutil_version=$(offline --entrypoint /usr/bin/gsutil "$image" version) || fail 'gsutil version failed'
printf '%s\n' "$gsutil_version" | grep -Eq '^gsutil version: [0-9]+\.[0-9]+' \
  || fail 'unexpected gsutil version output'

bq_version=$(offline --entrypoint /usr/bin/bq "$image" version) || fail 'bq version failed'
printf '%s\n' "$bq_version" | grep -Eq '^This is BigQuery CLI' || fail 'unexpected bq version output'

configured=$(offline --entrypoint /bin/sh "$image" -c \
  'gcloud config set project verity-project >/dev/null 2>&1 && gcloud config get-value project 2>/dev/null') \
  || fail 'gcloud config round trip failed'
[ "$configured" = verity-project ] || fail 'gcloud config did not persist the project in the home directory'

python3 "$work/server.py" "$work/port" &
server_pid=$!
attempts=0
until [ -s "$work/port" ]; do
  kill -0 "$server_pid" || fail 'storage fixture exited early'
  attempts=$((attempts + 1))
  [ "$attempts" -lt 20 ] || fail 'storage fixture did not start'
  sleep 1
done
port=$(cat "$work/port")

printf %s verity-token >"$work/token"
printf %s wrong-token >"$work/wrong-token"
chmod 644 "$work/token" "$work/wrong-token"
chmod 755 "$work"

storage() {
  token=$1
  endpoint=$2
  docker run --rm --network host --read-only --tmpfs /tmp --tmpfs /home/nonroot:uid=65532,gid=65532 \
    -v "$work/$token:/token:ro" \
    -e CLOUDSDK_CORE_DISABLE_USAGE_REPORTING=true -e CLOUDSDK_CORE_PROJECT=verity-project \
    -e CLOUDSDK_API_ENDPOINT_OVERRIDES_STORAGE="$endpoint" \
    "$image" storage ls --access-token-file=/token
}

storage token "http://127.0.0.1:$port/" | grep -Fq verity-smoke-bucket \
  || fail 'bucket listing did not contain the bucket'

if output=$(storage wrong-token "http://127.0.0.1:$port/" 2>&1); then
  fail 'listing with a rejected token succeeded'
fi
printf '%s\n' "$output" | grep -Fq 'verity invalid credentials' \
  || fail 'rejected token failed without the API error'

if output=$(storage token 'http://127.0.0.1:1/' 2>&1); then
  fail 'listing without connectivity succeeded'
fi
printf '%s\n' "$output" | grep -Eqi 'connect' || fail 'offline listing failed without a connection error'

printf 'SMOKE PASS image=%s\n' "$image"
