#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
version=$(sed -n 's/^  version: "\([^"]*\)".*$/\1/p' "$(dirname "$0")/../melange.yaml")
work=$(mktemp -d)
stub_pid=

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  [ -z "$stub_pid" ] || kill "$stub_pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

[ -n "$version" ] || fail 'could not read the recipe version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/docker"]' || fail 'unexpected entrypoint'

run() {
  docker run --rm --network none --read-only --cap-drop=ALL \
    --tmpfs /tmp:rw,mode=1777 -e HOME=/tmp "$@"
}

run "$image" --version >"$work/version" 2>&1 || fail 'version failed'
grep -Ex "Docker version $version, build [0-9a-f]{7,}" "$work/version" >/dev/null ||
  fail "unexpected version output: $(cat "$work/version")"

rc=0
run "$image" --definitely-invalid >"$work/flag" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'unknown flag: --definitely-invalid' "$work/flag" >/dev/null ||
  fail 'invalid flag diagnostic is missing'

# No daemon: the client section still renders, then the documented connection
# error and a non-zero exit.
rc=0
run "$image" version --format '{{.Client.Version}}' >"$work/client" 2>"$work/client.err" || rc=$?
test "$rc" -ne 0 || fail 'version without a daemon unexpectedly succeeded'
test "$(cat "$work/client")" = "$version" ||
  fail "client version is $(cat "$work/client"), expected $version"
grep -F 'failed to connect to the docker API at unix:///var/run/docker.sock' "$work/client.err" >/dev/null ||
  fail "missing daemon diagnostic: $(cat "$work/client.err")"

rc=0
run "$image" -H tcp://127.0.0.1:9 ps >"$work/tcp" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'ps against a closed TCP port unexpectedly succeeded'
grep -F 'Cannot connect to the Docker daemon at tcp://127.0.0.1:9' "$work/tcp" >/dev/null ||
  fail "missing TCP connection diagnostic: $(cat "$work/tcp")"

# Contexts persist in the client configuration directory.
# Run as the invoking user so the test can clean up the files it writes.
mkdir -p "$work/config"
run --user "$(id -u):$(id -g)" -v "$work/config:/config" -e DOCKER_CONFIG=/config "$image" \
  context create verity-smoke --description smoke --docker host=tcp://127.0.0.1:2376 \
  >"$work/context" 2>&1 || fail "context create failed: $(cat "$work/context")"
run --user "$(id -u):$(id -g)" -v "$work/config:/config" -e DOCKER_CONFIG=/config "$image" \
  context inspect verity-smoke --format '{{.Endpoints.docker.Host}}' >"$work/context.host" 2>&1 ||
  fail 'context inspect failed'
test "$(cat "$work/context.host")" = tcp://127.0.0.1:2376 ||
  fail "context endpoint is $(cat "$work/context.host")"
run --user "$(id -u):$(id -g)" -v "$work/config:/config" -e DOCKER_CONFIG=/config "$image" \
  context ls --format '{{.Name}}' >"$work/contexts" 2>&1 || fail 'context ls failed'
grep -Fx verity-smoke "$work/contexts" >/dev/null || fail 'created context is not listed'

# Engine API round trip against a stub daemon on a Unix socket: API version
# negotiation, /version and /containers/json.
mkdir -p "$work/sock"
chmod 0777 "$work/sock"
cat >"$work/stub.py" <<'PY'
import json
import os
import re
import socketserver
import sys
from http.server import BaseHTTPRequestHandler

SOCKET, LOG = sys.argv[1], sys.argv[2]
API = "1.47"
VERSION = {
    "Platform": {"Name": "Verity stub engine"},
    "Version": "0.0.0-verity-stub",
    "ApiVersion": API,
    "MinAPIVersion": "1.24",
    "GitCommit": "stub",
    "GoVersion": "go1.0",
    "Os": "linux",
    "Arch": "amd64",
    "KernelVersion": "stub",
    "BuildTime": "2026-01-01T00:00:00Z",
    "Components": [{"Name": "Engine", "Version": "0.0.0-verity-stub", "Details": {"ApiVersion": API}}],
}
CONTAINERS = [{
    "Id": "0" * 64,
    "Names": ["/verity-stub-container"],
    "Image": "verity/stub:1",
    "ImageID": "sha256:" + "1" * 64,
    "Command": "stub",
    "Created": 0,
    "Ports": [],
    "Labels": {},
    "State": "running",
    "Status": "Up 1 second",
    "HostConfig": {"NetworkMode": "none"},
    "NetworkSettings": {"Networks": {}},
    "Mounts": [],
}]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, status, body):
        data = json.dumps(body).encode() if body is not None else b""
        self.send_response(status)
        self.send_header("Api-Version", API)
        self.send_header("Ostype", "linux")
        self.send_header("Content-Type", "application/json" if body is not None else "text/plain")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def handle_one(self):
        with open(LOG, "a", encoding="utf-8") as log:
            log.write(f"{self.command} {self.path} {self.headers.get('User-Agent', '')}\n")
        path = self.path.split("?", 1)[0]
        if path == "/_ping":
            self.reply(200, None)
        elif re.fullmatch(r"/v[0-9.]+/version", path):
            self.reply(200, VERSION)
        elif re.fullmatch(r"/v[0-9.]+/containers/json", path):
            self.reply(200, CONTAINERS)
        else:
            self.reply(404, {"message": f"stub does not serve {path}"})

    do_GET = do_HEAD = handle_one


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True

    def get_request(self):
        request, _ = super().get_request()
        return request, ("stub", 0)


if os.path.exists(SOCKET):
    os.unlink(SOCKET)
with Server(SOCKET, Handler) as server:
    os.chmod(SOCKET, 0o777)
    server.serve_forever()
PY
python3 "$work/stub.py" "$work/sock/docker.sock" "$work/requests.log" &
stub_pid=$!
i=0
until [ -S "$work/sock/docker.sock" ]; do
  i=$((i + 1))
  [ "$i" -lt 50 ] || fail 'stub daemon socket did not appear'
  sleep 0.1
done

stub() {
  run -v "$work/sock:/run/stub" -e DOCKER_HOST=unix:///run/stub/docker.sock "$image" "$@"
}
stub version --format '{{.Server.Version}} {{.Client.APIVersion}} {{.Client.Version}}' \
  >"$work/server" 2>&1 || fail "version against the stub failed: $(cat "$work/server")"
test "$(cat "$work/server")" = "0.0.0-verity-stub 1.47 $version" ||
  fail "unexpected negotiated version output: $(cat "$work/server")"
stub ps --no-trunc --format '{{.Names}} {{.Image}} {{.State}}' >"$work/ps" 2>&1 ||
  fail "ps against the stub failed: $(cat "$work/ps")"
test "$(cat "$work/ps")" = 'verity-stub-container verity/stub:1 running' ||
  fail "unexpected ps output: $(cat "$work/ps")"
grep -E "^GET /v1\.47/containers/json(\?[^ ]*)? Docker-Client/$version \(linux\)$" \
  "$work/requests.log" >/dev/null ||
  fail "client did not use the negotiated API version: $(cat "$work/requests.log")"

rc=0
stub inspect verity-missing >"$work/missing" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'inspect of a missing object unexpectedly succeeded'

printf 'SMOKE PASS image=%s\n' "$image"
