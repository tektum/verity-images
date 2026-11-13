#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
recipe="$(dirname "$0")/../melange.yaml"
version=$(sed -n 's/^  version: "\([0-9.]*\)".*$/\1/p' "$recipe")
work=$(mktemp -d)
server_pid=

cleanup() {
  [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ -n "$version" ] || fail 'could not read the nuclei version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/nuclei"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

# -duc keeps every run offline: no engine or template update checks.
run() {
  network=$1
  shift
  docker run --rm --network "$network" --read-only --tmpfs /tmp:rw,mode=1777 \
    -e HOME=/tmp -v "$work/templates:/work:ro" "$image" -duc -no-color "$@"
}

mkdir -p "$work/templates"
cat >"$work/templates/banner.yaml" <<'YAML'
id: smoke-banner
info:
  name: Smoke banner detection
  author: verity
  severity: info
http:
  - method: GET
    path:
      - "{{BaseURL}}/banner"
    matchers-condition: and
    matchers:
      - type: status
        status:
          - 200
      - type: word
        part: body
        words:
          - "smoke-banner-ok"
    extractors:
      - type: regex
        part: body
        regex:
          - "build=[0-9]+"
YAML
cat >"$work/templates/absent.yaml" <<'YAML'
id: smoke-absent
info:
  name: Smoke absent path
  author: verity
  severity: low
http:
  - method: GET
    path:
      - "{{BaseURL}}/admin"
    matchers:
      - type: status
        status:
          - 200
YAML
cat >"$work/templates/invalid.yaml" <<'YAML'
id: smoke-invalid
info:
  name: Missing author and severity
http:
  - method: GET
    path:
      - "{{BaseURL}}/"
    matchers:
      - type: nosuchmatcher
YAML
chmod -R a+rX "$work"

docker run --rm --network none --read-only --tmpfs /tmp:rw,mode=1777 -e HOME=/tmp \
  "$image" -version >"$work/version" 2>&1 || fail 'version failed'
grep -F "Nuclei Engine Version: v$version" "$work/version" >/dev/null ||
  fail "version does not report v$version: $(cat "$work/version")"

run none -validate -t banner.yaml -t absent.yaml >"$work/valid" 2>&1 ||
  fail "valid templates were rejected: $(cat "$work/valid")"
grep -F 'All templates validated successfully' "$work/valid" >/dev/null ||
  fail "validation success message is missing: $(cat "$work/valid")"

rc=0
run none -validate -t invalid.yaml >"$work/invalid" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid template unexpectedly validated'
grep -F 'Invalid matcher type: nosuchmatcher' "$work/invalid" >/dev/null ||
  fail "invalid template diagnostic is missing: $(cat "$work/invalid")"

# Target fixture: a loopback server that exposes /banner and nothing else.
cat >"$work/server.py" <<'PY'
import http.server
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"smoke-banner-ok build=42\n" if self.path == "/banner" else b"no\n"
        self.send_response(200 if self.path == "/banner" else 404)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w", encoding="ascii") as port_file:
    port_file.write(str(server.server_port))
server.serve_forever()
PY
python3 "$work/server.py" "$work/port" &
server_pid=$!
attempt=0
until [ -s "$work/port" ]; do
  kill -0 "$server_pid" 2>/dev/null || fail 'target fixture exited early'
  attempt=$((attempt + 1))
  [ "$attempt" -lt 20 ] || fail 'target fixture did not start'
  sleep 1
done
port=$(cat "$work/port")

# Scan: the banner template matches and extracts, the absent template does not.
run host -u "http://127.0.0.1:$port" -t banner.yaml -t absent.yaml -jsonl -silent \
  >"$work/results" 2>"$work/scan.err" || fail "scan failed: $(cat "$work/scan.err")"
test "$(grep -c . "$work/results")" -eq 1 ||
  fail "expected exactly one finding: $(cat "$work/results")"
grep -F '"template-id":"smoke-banner"' "$work/results" >/dev/null ||
  fail "banner finding is missing: $(cat "$work/results")"
grep -F '"extracted-results":["build=42"]' "$work/results" >/dev/null ||
  fail "extracted value is missing: $(cat "$work/results")"
grep -F "\"matched-at\":\"http://127.0.0.1:$port/banner\"" "$work/results" >/dev/null ||
  fail "matched URL is missing: $(cat "$work/results")"

printf 'SMOKE PASS\n'
