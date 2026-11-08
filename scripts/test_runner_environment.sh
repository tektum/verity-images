#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# The suite itself may run on a RunsOn runner whose real RUNS_ON_* variables must not leak in.
unset IMDSV1 LIFECYCLE PENDING_TIME RUNNER_ENVIRONMENT RUNNER_NAME RUNS_ON_INSTANCE_ID RUNS_ON_RUNNER_NAME \
  RUNS_ON_VERSION RUNS_ON_STACK_NAME RUNS_ON_INSTANCE_LAUNCHED_AT RUNS_ON_POOL_NAME
work=$(mktemp -d)
server=
trap '[[ -z "$server" ]] || kill "$server" 2>/dev/null; rm -rf "$work"' EXIT

# Fake IMDS: IMDSv2 only unless IMDSV1=1; PENDING_TIME is the instance start.
cat >"$work/imds.py" <<'EOF'
import http.server, json, os, sys

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, body=""):
        self.send_response(code)
        self.end_headers()
        self.wfile.write(body.encode())

    def do_PUT(self):
        self.reply(200, "token")

    def do_GET(self):
        if self.headers.get("X-aws-ec2-metadata-token") != "token" and not os.environ.get("IMDSV1"):
            return self.reply(401)
        if self.path.endswith("/instance-life-cycle"):
            return self.reply(200, os.environ.get("LIFECYCLE", "on-demand"))
        if self.path.endswith("/instance-id"):
            return self.reply(200, "i-0abc")
        if self.path.endswith("/instance-identity/document"):
            return self.reply(200, json.dumps({
                "instanceId": "i-0abc", "imageId": "ami-0abc", "instanceType": "c8i.4xlarge",
                "architecture": "x86_64", "region": "us-east-1", "availabilityZone": "us-east-1a",
                "pendingTime": os.environ["PENDING_TIME"]}))
        self.reply(404)

server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
open(sys.argv[1], "w").write(str(server.server_port))
server.serve_forever()
EOF

start_imds() {
  [[ -z "$server" ]] || kill "$server" 2>/dev/null || true
  rm -f "$work/port"
  python3 "$work/imds.py" "$work/port" &
  server=$!
  until [[ -s "$work/port" ]]; do sleep 0.05; done
  IMDS_ENDPOINT="http://127.0.0.1:$(<"$work/port")"
  export IMDS_ENDPOINT
}

collect() {
  RUNNER_NAME='runs-on--i-0abc--job' RUNS_ON_RUNNER_NAME="${RUNS_ON_RUNNER_NAME:-runs-on--i-0abc--job}" \
    RUNS_ON_INSTANCE_ID="${RUNS_ON_INSTANCE_ID:-i-0abc}" RUNS_ON_STACK_NAME=runs-on \
    BUILDER_ID=builder JOB_INDEX=0 MAX_INSTANCE_AGE_SECONDS=900 IMDS_RETRY_DELAY=0 \
    "$root/scripts/runner_environment.sh" collect "$work/predicate.json" 2>"$work/err"
}

expect_failure() {
  if collect; then
    printf 'accepted: %s\n' "$1" >&2
    exit 1
  fi
  grep -q "$2" "$work/err" || { printf 'wrong failure for %s:\n' "$1" >&2; cat "$work/err" >&2; exit 1; }
}

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
old=$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)

PENDING_TIME=$now start_imds
collect || { cat "$work/err" >&2; exit 1; }
jq -e '.instance.id == "i-0abc" and .instance.lifecycle == "on-demand"
  and .checks.imdsV1Refused and .runsOn.stack == "runs-on"' "$work/predicate.json" >/dev/null
RUNS_ON_INSTANCE_ID=i-other expect_failure 'instance mismatch' 'is not i-0abc'
RUNS_ON_RUNNER_NAME=other expect_failure 'runner mismatch' 'is not registered'

PENDING_TIME=$old start_imds
expect_failure 'reused instance' 'instance started'

PENDING_TIME=$now IMDSV1=1 start_imds
expect_failure 'IMDSv1 enabled' 'IMDSv1 is not refused'

PENDING_TIME=$now LIFECYCLE=spot start_imds
expect_failure 'spot instance' 'not on-demand'

export IMDS_ENDPOINT=http://127.0.0.1:9
expect_failure 'unreachable IMDS' 'IMDS is unreachable'

# Materials: the evidence file and every present tool archive become descriptors.
cd "$work"
mkdir -p dist/x
printf '{}' >dist/x/apko.lock.json
printf 'dist/x/apko.lock.json\n' >dist/x/evidence-path
jq -n '{resolvedDependencies: []}' >p.json
"$root/scripts/runner_environment.sh" materials p.json dist/x
jq -e '.resolvedDependencies | length >= 1 and .[0].name == "dist/x/apko.lock.json"
  and (.[0].digest.sha256 | test("^[0-9a-f]{64}$"))' p.json >/dev/null
