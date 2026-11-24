#!/bin/sh
set -eu

# Every scan targets a loopback fixture on the host network; no third-party
# host is probed.
image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^  version: "\([0-9][0-9.]*\)".*/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf '%s\n' 'nmap melange version not found' >&2; exit 1; }
work=$(mktemp -d)
server_pid=
cleanup() {
  [ -z "$server_pid" ] || kill "$server_pid" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

run() {
  timeout 120 docker run --rm "$@"
}

user=$(docker image inspect -f '{{.Config.User}}' "$image")
[ "$user" = 65532 ] || fail "image user is $user, want 65532"
entrypoint=$(docker image inspect -f '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' "$image")
[ "$entrypoint" = '["/usr/bin/nmap"] null' ] || fail "unexpected entrypoint: $entrypoint"
workdir=$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")
[ "$workdir" = /work ] || fail "unexpected working directory: $workdir"

version=$(run --network none "$image" --version 2>&1) || fail "nmap --version failed: $version"
printf '%s\n' "$version" | grep -E "^Nmap version $expected_version " >/dev/null ||
  fail "unexpected version: $version"
compiled=$(printf '%s\n' "$version" | sed -n 's/^Compiled with: //p')
for feature in liblua openssl libssh2 libz libpcre2 libpcap; do
  printf ' %s\n' "$compiled" | grep -F " $feature-" >/dev/null || fail "nmap is not compiled with $feature: $version"
done
# Nmap is distributed under the Nmap Public Source License; the image must
# carry its text next to the binaries.
cid=$(docker create "$image")
docker cp "$cid:/usr/share/licenses/verity-nmap/LICENSE" "$work/LICENSE" >/dev/null 2>&1 ||
  { docker rm "$cid" >/dev/null; fail 'NPSL license text is missing from the image'; }
docker rm "$cid" >/dev/null
head -n1 "$work/LICENSE" | grep -E '^Nmap Public Source License Version [0-9.]+$' >/dev/null ||
  fail 'shipped license is not the Nmap Public Source License'

for tool in ncat nping; do
  run --network none --entrypoint "/usr/bin/$tool" "$image" --version >/dev/null 2>&1 ||
    fail "$tool --version failed"
done

cat >"$work/server.py" <<'PY'
import http.server
import socket
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"<html><head><title>verity nmap fixture</title></head></html>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_HEAD = do_GET

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
# Version probes send malformed requests and reset connections.
server.handle_error = lambda *args: None
closed = socket.socket()
closed.bind(("127.0.0.1", 0))
closed_port = closed.getsockname()[1]
closed.close()
with open(sys.argv[1], "w") as port_file:
    port_file.write(f"{server.server_port} {closed_port}\n")
server.serve_forever()
PY
python3 "$work/server.py" "$work/ports" &
server_pid=$!
attempts=0
until [ -s "$work/ports" ]; do
  kill -0 "$server_pid" 2>/dev/null || fail 'fixture server exited'
  attempts=$((attempts + 1))
  [ "$attempts" -lt 20 ] || fail 'fixture server did not start'
  sleep 1
done
read -r open_port closed_port <"$work/ports"

# Unprivileged connect scan with service detection and an NSE script; this
# exercises nmap-services, nmap-service-probes, nse_main.lua and nselib.
out=$(run --network host "$image" -n -Pn -sT -sV --version-light --script http-title,http-server-header \
  -p "$open_port,$closed_port" -oX - 127.0.0.1 2>&1) ||
  { printf '%s\n' "$out" >&2; fail 'connect scan failed'; }
printf '%s\n' "$out" | grep -E "portid=\"$open_port\"><state state=\"open\"" >/dev/null ||
  { printf '%s\n' "$out" >&2; fail "port $open_port was not reported open"; }
printf '%s\n' "$out" | grep -E "portid=\"$closed_port\"><state state=\"closed\"" >/dev/null ||
  { printf '%s\n' "$out" >&2; fail "port $closed_port was not reported closed"; }
printf '%s\n' "$out" | grep -F '<service name="http"' >/dev/null ||
  { printf '%s\n' "$out" >&2; fail 'service detection did not identify http'; }
printf '%s\n' "$out" | grep -F 'id="http-title" output="verity nmap fixture"' >/dev/null ||
  { printf '%s\n' "$out" >&2; fail 'http-title NSE script did not report the fixture title'; }
printf '%s\n' "$out" | grep -E 'id="http-server-header" output="BaseHTTP/[0-9.]+ Python/' >/dev/null ||
  { printf '%s\n' "$out" >&2; fail 'http-server-header NSE script did not run'; }

# The image runs as non-root without raw-socket privileges: a SYN scan must
# be refused rather than silently degrade.
if out=$(run --network host "$image" -n -Pn -sS -p "$open_port" 127.0.0.1 2>&1); then
  printf '%s\n' "$out" >&2
  fail 'SYN scan succeeded without raw-socket privileges'
fi
printf '%s\n' "$out" | grep -F 'requires root privileges' >/dev/null ||
  { printf '%s\n' "$out" >&2; fail 'SYN scan was not refused for missing privileges'; }

printf 'SMOKE PASS image=%s\n' "$image"
