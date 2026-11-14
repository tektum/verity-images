#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
version=$(sed -n 's/^    - aws-nuke=\([0-9.]*\)-r[0-9]*$/\1/p' "$here/../apko.yaml")
# Catalog Python 3.13, pinned by index digest, serves a fake EC2 API on loopback.
python_index=ghcr.io/tektum/python@sha256:d059268a2e4f0ef0cc82bb50c847e69e16e174736758013a153cb36311fa6dd6
fake="verity-aws-nuke-ec2-$$"
work=$(mktemp -d)

# AWS documentation example keys. Every run below has no network route
# (--network none, or the loopback-only namespace of a --network none
# container), so nothing can reach AWS whatever the credentials are.
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

[ -n "$version" ] || fail 'could not read the pinned aws-nuke version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/aws-nuke"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'

mkdir -p "$work/cfg" "$work/log"
chmod 755 "$work/cfg"
chmod 777 "$work/log"

# Offline, read-only root, no capabilities, no host environment.
run() {
  docker run --rm --network none --read-only --cap-drop=ALL \
    -v "$work/cfg:/cfg:ro" "$image" "$@"
}

run version >"$work/version" 2>&1 || fail "version failed: $(cat "$work/version")"
grep -Fx "aws-nuke version v$version" "$work/version" >/dev/null ||
  fail "version does not report v$version: $(cat "$work/version")"

status=0
run --definitely-invalid >"$work/invalid" 2>&1 || status=$?
test "$status" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"

run resource-types >"$work/types" 2>&1 || fail "resource-types failed: $(cat "$work/types")"
for type in EC2Instance S3Bucket IAMRole LambdaFunction CloudFormationStack; do
  grep -Eq "^${type}[[:space:]]+native resource\$" "$work/types" || fail "resource-types is missing $type"
done

# Configuration validation, fully offline: --account-id skips authentication.
cat >"$work/cfg/explain.yaml" <<'EOF'
regions:
  - us-east-1
blocklist:
  - "999999999999"
resource-types:
  includes:
    - S3Bucket
    - EC2Instance
    - IAMRole
accounts:
  "000000000000":
    presets: [keep]
    resource-types:
      excludes:
        - IAMRole
presets:
  keep:
    filters:
      S3Bucket:
        - verity-keep
      EC2Instance:
        - property: tag:Owner
          value: platform
EOF
# Every registered type is one unindented line (native or cloud-control resource).
total=$(grep -Ec '^[A-Z][A-Za-z0-9:]+[[:space:]]+(native|cloud-control) resource$' "$work/types")
run explain-config -c /cfg/explain.yaml --account-id 000000000000 --with-included --with-filtered \
  >"$work/explain" 2>&1 || fail "explain-config failed: $(cat "$work/explain")"
for line in 'Account ID:       000000000000' '      Included:   2' 'Filter Presets:   1' \
  'Resource Filters: 2'; do
  grep -Fx "$line" "$work/explain" >/dev/null || fail "explain-config is missing '$line': $(cat "$work/explain")"
done
test "$total" -gt 400 || fail "resource-types listed only $total types"
grep -Fx "Resource Types:   $total (total)" "$work/explain" >/dev/null ||
  fail "explain-config total differs from the $total listed types: $(cat "$work/explain")"
# Global includes minus the account exclude: exactly S3Bucket and EC2Instance.
sed -n '/^Resource Types:$/,/^$/p' "$work/explain" | sed -n 's/^  //p' | sort >"$work/included"
printf 'EC2Instance\nS3Bucket\n' >"$work/want"
cmp -s "$work/included" "$work/want" || fail "unexpected included types: $(cat "$work/included")"

status=0
run explain-config -c /cfg/explain.yaml --account-id 111111111111 >"$work/unknown" 2>&1 || status=$?
test "$status" -ne 0 || fail 'explain-config accepted an unconfigured account'
grep -F 'account 111111111111 is not configured in the config file' "$work/unknown" >/dev/null ||
  fail "unconfigured account diagnostic is missing: $(cat "$work/unknown")"

printf 'regions: [us-east-1\naccounts: {\n' >"$work/cfg/broken.yaml"
status=0
run explain-config -c /cfg/broken.yaml --account-id 000000000000 >"$work/broken" 2>&1 || status=$?
test "$status" -ne 0 || fail 'explain-config accepted malformed YAML'
grep -F 'Failed to parse config file /cfg/broken.yaml' "$work/broken" >/dev/null ||
  fail "malformed YAML diagnostic is missing: $(cat "$work/broken")"

# A run in a region that is neither an AWS region nor a configured custom
# endpoint is refused before any request.
status=0
run run -c /cfg/explain.yaml --access-key-id "$key_id" --secret-access-key "$secret" \
  --default-region verity-nowhere >"$work/region" 2>&1 || status=$?
test "$status" -ne 0 || fail 'run accepted an unknown region'
grep -F "the custom region 'verity-nowhere' must be specified in the configuration 'endpoints'" \
  "$work/region" >/dev/null || fail "unknown region diagnostic is missing: $(cat "$work/region")"

# Dry run (the default) against a fake EC2 endpoint on loopback. The fake runs
# with --network none and aws-nuke joins its namespace, which has only
# loopback. It lists three instances and records every API action it receives.
cat >"$work/cfg/fake_ec2.py" <<'EOF'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs

INSTANCE = """<item><instanceId>{id}</instanceId><imageId>ami-0verity</imageId>
<instanceState><code>{code}</code><name>{state}</name></instanceState>
<instanceType>t3.micro</instanceType><launchTime>2026-01-01T00:00:00.000Z</launchTime>
<tagSet>{tags}</tagSet></item>"""
TAG = "<item><key>{k}</key><value>{v}</value></item>"
BODY = """<?xml version="1.0" encoding="UTF-8"?>
<DescribeInstancesResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
<requestId>verity-1</requestId><reservationSet><item><reservationId>r-0verity</reservationId>
<instancesSet>{items}</instancesSet></item></reservationSet></DescribeInstancesResponse>"""
ITEMS = "".join([
    INSTANCE.format(id="i-0000000000000000a", code=16, state="running",
                    tags=TAG.format(k="Name", v="scratch")),
    INSTANCE.format(id="i-0000000000000000b", code=16, state="running",
                    tags=TAG.format(k="Owner", v="platform")),
    INSTANCE.format(id="i-0000000000000000c", code=48, state="terminated", tags=""),
])
ERROR = b"<Response><Errors><Error><Code>Unsupported</Code></Error></Errors></Response>"


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        action = parse_qs(self.rfile.read(length).decode()).get("Action", ["?"])[0]
        with open(sys.argv[2], "a", encoding="utf-8") as log:
            log.write(f"{self.command} {action}\n")
        if action == "DescribeInstances":
            payload, status = BODY.format(items=ITEMS).encode(), 200
        else:
            payload, status = ERROR, 400
        self.send_response(status)
        self.send_header("Content-Type", "text/xml")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    do_GET = do_POST

    def log_message(self, *args):
        pass


HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
EOF
# A custom stack without sts and iam endpoints has a synthetic account id, so
# aws-nuke needs no identity call. The empty service is the default session
# endpoint; it is listed last because services match resource types by prefix.
dry_config() {
  cat <<EOF
regions:
  - verity-local
blocklist:
  - "$1"
resource-types:
  includes:
    - EC2Instance
accounts:
  account-id-of-custom-region-verity-local:
    presets: [platform]
presets:
  platform:
    filters:
      EC2Instance:
        - property: tag:Owner
          value: platform
endpoints:
  - region: verity-local
    services:
      - service: ec2
        url: http://127.0.0.1:8080/
      - service: ""
        url: http://127.0.0.1:8080/
EOF
}
dry_config 999999999999 >"$work/cfg/dry.yaml"
dry_config account-id-of-custom-region-verity-local >"$work/cfg/blocked.yaml"
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

docker run -d --name "$fake" --network none --read-only --cap-drop=ALL --user 65532:65532 \
  -v "$work/cfg:/cfg:ro" -v "$work/log:/log" "$python_image" \
  /cfg/fake_ec2.py 8080 /log/requests.log >/dev/null || fail 'could not start the fake EC2 endpoint'
i=0
until docker exec "$fake" python3 -c \
  'import socket; socket.create_connection(("127.0.0.1", 8080), 1).close()' >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -le 30 ] || fail "fake EC2 endpoint did not listen: $(docker logs "$fake" 2>&1)"
  sleep 1
done

nuke() {
  timeout 120 docker run --rm --network "container:$fake" --read-only --cap-drop=ALL \
    -v "$work/cfg:/cfg:ro" "$image" run -c "/cfg/$1" --access-key-id "$key_id" \
    --secret-access-key "$secret" --default-region verity-local --force --force-sleep 3
}

# Negative first: a blocklisted account is refused before any API call.
status=0
nuke blocked.yaml >"$work/blocked" 2>&1 || status=$?
test "$status" -ne 0 || fail 'run against a blocklisted account succeeded'
grep -F 'account is in blocklist' "$work/blocked" >/dev/null ||
  fail "blocklist diagnostic is missing: $(cat "$work/blocked")"
test ! -s "$work/log/requests.log" ||
  fail "blocklisted run reached the endpoint: $(cat "$work/log/requests.log")"

nuke dry.yaml >"$work/dry" 2>&1 || fail "dry run failed: $(cat "$work/dry")"
grep -E '^verity-local - EC2Instance - i-0000000000000000a - .*tag:Name: "scratch".* - would remove$' \
  "$work/dry" >/dev/null || fail "untagged instance is not marked for removal: $(cat "$work/dry")"
grep -E '^verity-local - EC2Instance - i-0000000000000000b - .* - filtered: filtered by config$' \
  "$work/dry" >/dev/null || fail "preset filter did not keep the platform instance: $(cat "$work/dry")"
grep -E '^verity-local - EC2Instance - i-0000000000000000c - .* - filtered: already terminated$' \
  "$work/dry" >/dev/null || fail "terminated instance is not filtered: $(cat "$work/dry")"
grep -Fx 'Scan complete: 3 total, 1 nukeable, 2 filtered.' "$work/dry" >/dev/null ||
  fail "unexpected scan summary: $(cat "$work/dry")"
grep -F 'Provide --no-dry-run to actually destroy resources.' "$work/dry" >/dev/null ||
  fail "dry-run notice is missing: $(cat "$work/dry")"
# The dry run only listed: the endpoint saw DescribeInstances and nothing else,
# no TerminateInstances, ModifyInstanceAttribute or DeleteTags.
grep -q . "$work/log/requests.log" || fail 'dry run never reached the endpoint'
if grep -vFx 'POST DescribeInstances' "$work/log/requests.log" >"$work/other"; then
  fail "dry run sent non-list API actions: $(cat "$work/other")"
fi

echo 'SMOKE PASS'
