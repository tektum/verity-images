#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
recipe="$(dirname "$0")/../melange.yaml"
version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' "$recipe")
work=$(mktemp -d)
server_pid=

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail 'could not read the recipe version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/lychee"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'CA bundle environment is missing'

# Every run uses a read-only root and drops all capabilities; only the
# local-server cases get the host network, everything else has none.
lychee_none() {
  docker run --rm --network none --read-only --cap-drop ALL \
    -v "$work/fixtures:/work:ro" "$image" "$@"
}
lychee_host() {
  docker run --rm --network host --read-only --cap-drop ALL \
    -v "$work/fixtures:/work:ro" "$image" "$@"
}

mkdir "$work/fixtures"

lychee_none --version >"$work/version" 2>&1 || fail 'version failed'
grep -Fx "lychee $version" "$work/version" >/dev/null ||
  fail "version does not report lychee $version: $(cat "$work/version")"

rc=0
lychee_none --definitely-invalid >"$work/invalid" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F "unexpected argument '--definitely-invalid' found" "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"

# Offline: remote links are excluded without any network access, the relative
# file link is resolved on disk.
cat >"$work/fixtures/offline.md" <<'EOF'
# Offline fixture

- [remote](https://verity.invalid/remote)
- [also remote](http://192.0.2.1/unreachable)
- [local file](./target.md)
EOF
printf '# Target\n' >"$work/fixtures/target.md"

# The image builds lychee without the email-check feature: a mail address is
# excluded instead of probed over DNS and SMTP, even with --include-mail.
printf 'Contact [us](mailto:nobody@verity.invalid).\n' >"$work/fixtures/mail.md"

# Local server only: one 200 page, everything else 404.
cat >"$work/fixtures/links.html" <<'EOF'
<!doctype html>
<html><body>
<a href="http://127.0.0.1:@PORT@/good.html">good</a>
<a href="http://127.0.0.1:@PORT@/missing.html">missing</a>
</body></html>
EOF
printf '# Good only\n\n[good](http://127.0.0.1:@PORT@/good.html)\n' >"$work/fixtures/good.md"

cat >"$work/server.py" <<'PY'
import http.server
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/good.html":
            body = b"<!doctype html><title>good</title>\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
        else:
            body = b"not found\n"
            self.send_response(404)
            self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command == "GET":
            self.wfile.write(body)

    do_HEAD = do_GET

    def log_message(self, *args):
        with open(sys.argv[2], "a", encoding="ascii") as log:
            log.write(self.command + " " + self.path + "\n")


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w", encoding="ascii") as port_file:
    port_file.write(str(server.server_port))
server.serve_forever()
PY
python3 "$work/server.py" "$work/port" "$work/requests.log" &
server_pid=$!
attempt=0
until [ -s "$work/port" ]; do
  kill -0 "$server_pid" 2>/dev/null || fail 'local server exited early'
  attempt=$((attempt + 1))
  [ "$attempt" -lt 20 ] || fail 'local server did not start'
  sleep 1
done
port=$(cat "$work/port")
sed -i "s/@PORT@/$port/g" "$work/fixtures/links.html" "$work/fixtures/good.md"
chmod 755 "$work/fixtures"
chmod 644 "$work/fixtures"/*

lychee_none --offline --no-progress --format json offline.md >"$work/offline.json" 2>"$work/offline.err" ||
  fail "offline check failed: $(cat "$work/offline.json" "$work/offline.err")"
jq -e '.total == 3 and .successful == 1 and .excludes == 2 and .errors == 0' \
  "$work/offline.json" >/dev/null || fail "unexpected offline summary: $(cat "$work/offline.json")"
lychee_none --offline --no-progress --mode plain offline.md >"$work/offline.txt" 2>&1 ||
  fail "offline plain check failed: $(cat "$work/offline.txt")"
grep -E '3 Total .* 1 OK .* 0 Errors .* 2 Excluded' "$work/offline.txt" >/dev/null ||
  fail "unexpected offline plain summary: $(cat "$work/offline.txt")"

# lychee needs no writable directory unless --cache is requested: the cache is
# written to .lycheecache in the working directory, so that needs a tmpfs.
rc=0
lychee_none --offline --no-progress --cache offline.md >"$work/cache-ro" 2>&1 || rc=$?
test "$rc" -ne 0 || fail '--cache on a read-only working directory unexpectedly succeeded'
grep -F 'Read-only file system' "$work/cache-ro" >/dev/null ||
  fail "read-only cache diagnostic is missing: $(cat "$work/cache-ro")"
docker run --rm --network none --read-only --cap-drop ALL \
  --tmpfs /work:uid=65532,gid=65532 -v "$work/fixtures:/fixtures:ro" \
  "$image" --offline --no-progress --cache /fixtures/offline.md >"$work/cache-tmpfs" 2>&1 ||
  fail "--cache on a tmpfs working directory failed: $(cat "$work/cache-tmpfs")"

lychee_none --no-progress --include-mail --format json mail.md >"$work/mail.json" 2>"$work/mail.err" ||
  fail "mail check failed: $(cat "$work/mail.json" "$work/mail.err")"
jq -e '.total == 1 and .excludes == 1 and .errors == 0' "$work/mail.json" >/dev/null ||
  fail "mail address was not excluded: $(cat "$work/mail.json")"

rc=0
lychee_host --no-progress --verbose --format json links.html >"$work/links.json" 2>"$work/links.err" || rc=$?
test "$rc" -ne 0 || fail 'a broken link unexpectedly exited 0'
jq -e --arg good "http://127.0.0.1:$port/good.html" --arg bad "http://127.0.0.1:$port/missing.html" '
  .total == 2 and .successful == 1 and .errors == 1
  and ([.success_map[][] | .url] == [$good])
  and ([.error_map[][] | select(.status.code == 404) | .url] == [$bad])' \
  "$work/links.json" >/dev/null || fail "unexpected local server result: $(cat "$work/links.json")"
rc=0
lychee_host --no-progress --mode plain links.html >"$work/links.txt" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'a broken link unexpectedly exited 0 in plain mode'
grep -F "[404] http://127.0.0.1:$port/missing.html" "$work/links.txt" >/dev/null ||
  fail "404 diagnostic is missing: $(cat "$work/links.txt")"

lychee_host --no-progress --format json good.md >"$work/good.json" 2>"$work/good.err" ||
  fail "good-only check failed: $(cat "$work/good.json" "$work/good.err")"
jq -e '.total == 1 and .successful == 1 and .errors == 0' "$work/good.json" >/dev/null ||
  fail "unexpected good-only summary: $(cat "$work/good.json")"

grep -Ex '(GET|HEAD) /good.html' "$work/requests.log" >/dev/null ||
  fail 'local server never saw a request for /good.html'
grep -Ex '(GET|HEAD) /missing.html' "$work/requests.log" >/dev/null ||
  fail 'local server never saw a request for /missing.html'

printf 'SMOKE PASS image=%s\n' "$image"
