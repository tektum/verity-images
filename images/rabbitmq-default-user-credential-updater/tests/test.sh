#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
stub_pids=
label=verity.test=rabbitmq-default-user-credential-updater-$$

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -fv >/dev/null 2>&1 || true
  for pid in $stub_pids; do
    kill "$pid" >/dev/null 2>&1 || true
  done
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/default-user-credential-updater"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'

run() {
  docker run --rm --label "$label" --read-only --cap-drop=ALL "$@"
}

run --network none "$image" --help >"$work/help" 2>&1 || fail "--help failed: $(cat "$work/help")"
for flag in -default-user-file -admin-file -management-uri -ca-file; do
  grep -F -- "$flag" "$work/help" >/dev/null || fail "--help does not list $flag"
done
for default in /etc/rabbitmq/conf.d/11-default_user.conf /var/lib/rabbitmq/.rabbitmqadmin.conf \
  http://127.0.0.1:15672 /etc/rabbitmq-tls/ca.crt; do
  grep -F "\"$default\"" "$work/help" >/dev/null || fail "--help does not show default $default"
done
# The upstream image installs the binary as /default-user-credential-updater.
run --network none --entrypoint /default-user-credential-updater "$image" --help \
  >"$work/help-compat" 2>&1 || fail "compat path is not executable: $(cat "$work/help-compat")"
sed 1d "$work/help" >"$work/help.body"
sed 1d "$work/help-compat" >"$work/help-compat.body"
cmp -s "$work/help.body" "$work/help-compat.body" ||
  fail '/default-user-credential-updater is not the updater binary'

rc=0
run --network none "$image" --definitely-invalid >"$work/invalid" 2>&1 || rc=$?
test "$rc" -eq 2 || fail "invalid flag exited $rc"
grep -F 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"

# Stub of the RabbitMQ management API on the runner loopback. It holds one
# administrator, "guest", whose current password lives in STATE/password, and
# logs each request as "METHOD PATH USER:PASSWORD [canonical JSON body]".
cat >"$work/mgmt.py" <<'PY'
import base64
import http.server
import json
import os
import ssl
import sys

port_file, log_file, state = sys.argv[1:4]
USER = "guest"
TAGS = ["administrator", "monitoring"]
HASHING = "rabbit_password_hashing_sha512"


def password():
    with open(os.path.join(state, "password"), encoding="ascii") as f:
        return f.read().strip()


class Handler(http.server.BaseHTTPRequestHandler):
    def reply(self, code, payload=None):
        body = b"" if payload is None else json.dumps(payload).encode()
        self.send_response(code)
        if payload is not None:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def handle_any(self):
        body = b""
        if "Content-Length" in self.headers:
            body = self.rfile.read(int(self.headers["Content-Length"]))
        creds = "-:-"
        header = self.headers.get("Authorization", "")
        if header.startswith("Basic "):
            creds = base64.b64decode(header[6:]).decode()
        entry = f"{self.command} {self.path} {creds}"
        if body:
            entry += " " + json.dumps(json.loads(body), sort_keys=True)
        with open(log_file, "a", encoding="ascii") as log:
            log.write(entry + "\n")
        if creds != f"{USER}:{password()}":
            return self.reply(401, {"error": "not_authorized", "reason": "Login failed"})
        if self.command == "GET" and self.path == "/api/whoami":
            return self.reply(200, {"name": USER, "tags": TAGS})
        if self.path != f"/api/users/{USER}":
            return self.reply(404, {"error": "Object Not Found", "reason": "Not Found"})
        if self.command == "GET":
            return self.reply(200, {"name": USER, "password_hash": "x",
                                    "hashing_algorithm": HASHING, "tags": TAGS, "limits": {}})
        if self.command == "PUT":
            new = json.loads(body)["password"]
            with open(os.path.join(state, "password"), "w", encoding="ascii") as f:
                f.write(new + "\n")
            return self.reply(204)
        return self.reply(405, {"error": "Method Not Allowed", "reason": "Method Not Allowed"})

    do_GET = do_PUT = handle_any

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
if len(sys.argv) > 4:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(sys.argv[4], sys.argv[5])
    server.socket = context.wrap_socket(server.socket, server_side=True)
with open(port_file, "w", encoding="ascii") as f:
    f.write(str(server.server_port))
server.serve_forever()
PY

# start_stub NAME [CERT KEY]: starts a stub whose files live in $work/NAME.
start_stub() {
  name=$1
  shift
  mkdir -p "$work/$name"
  : >"$work/$name/requests.log"
  python3 "$work/mgmt.py" "$work/$name/port" "$work/$name/requests.log" "$work/$name" "$@" &
  stub_pids="$stub_pids $!"
  attempt=0
  until [ -s "$work/$name/port" ]; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 50 ] || fail "stub $name did not start"
    sleep 0.2
  done
}

server_password() {
  printf '%s\n' "$2" >"$work/$1/password"
}

# new_node NAME USER PASSWORD: pod volumes with matching default-user and
# rabbitmqadmin files, writable by the image's nonroot user.
new_node() {
  mkdir -p "$work/$1/conf.d" "$work/$1/lib"
  chmod 0777 "$work/$1/conf.d" "$work/$1/lib"
  printf 'default_user = %s\ndefault_pass = %s\n' "$2" "$3" >"$work/$1/conf.d/11-default_user.conf"
  printf '[default]\nusername=%s\npassword=%s\n' "$2" "$3" >"$work/$1/lib/.rabbitmqadmin.conf"
  chmod 0666 "$work/$1/lib/.rabbitmqadmin.conf"
}

# vault_render NODE USER PASSWORD: replace the default-user file the way the
# Vault agent does, by renaming a fully written file into place.
vault_render() {
  printf 'default_user = %s\ndefault_pass = %s\n' "$2" "$3" >"$work/$1/conf.d/.render"
  mv "$work/$1/conf.d/.render" "$work/$1/conf.d/11-default_user.conf"
}

# start_updater NODE MANAGEMENT_URI [CA_FILE]: runs the sidecar with the default
# file paths, as the cluster operator does, mounting CA_FILE at the default
# --ca-file path.
start_updater() {
  node=$1 management_uri=$2 ca_file=${3:-}
  set -- -v "$work/$node/conf.d:/etc/rabbitmq/conf.d" -v "$work/$node/lib:/var/lib/rabbitmq"
  if [ -n "$ca_file" ]; then
    set -- "$@" -v "$ca_file:/etc/rabbitmq-tls/ca.crt:ro"
  fi
  docker run -d --label "$label" --read-only --cap-drop=ALL --network host "$@" \
    "$image" --management-uri "$management_uri" -v 4 >"$work/$node/cid"
}

logs() {
  docker logs "$(cat "$work/$1/cid")" 2>&1
}

# The updater logs only verbosity 0 and errors (its text logger ignores -v), so
# there is no readiness line. Events are handled one at a time, so until the
# first render is acted on, re-rendering the same content is idempotent: once
# a render was processed, the next one finds matching passwords and does nothing.
# first_render NODE USER PASSWORD DESCRIPTION COMMAND...: renders until COMMAND
# succeeds, for up to 60 seconds.
first_render() {
  render_node=$1 render_user=$2 render_password=$3 description=$4
  shift 4
  attempt=0
  until "$@" >/dev/null 2>&1; do
    if [ $((attempt % 10)) -eq 0 ]; then
      vault_render "$render_node" "$render_user" "$render_password"
    fi
    attempt=$((attempt + 1))
    [ "$attempt" -lt 300 ] || fail "timed out waiting for $description"
    sleep 0.2
  done
}

# wait_for DESCRIPTION COMMAND...: polls for up to 30 seconds.
wait_for() {
  description=$1
  shift
  attempt=0
  until "$@" >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 150 ] || fail "timed out waiting for $description"
    sleep 0.2
  done
}

log_has() {
  logs "$1" | grep -F -- "$2"
}

admin_password_is() {
  grep -Ex "password *= *$2" "$work/$1/lib/.rabbitmqadmin.conf"
}

admin_password_matches() {
  admin_password_is "$@" >/dev/null || fail "$1 rabbitmqadmin password is not $2: $(cat "$work/$1/lib/.rabbitmqadmin.conf")"
}

running() {
  test "$(docker inspect --format '{{.State.Running}}' "$(cat "$work/$1/cid")")" = true
}

exited() {
  test "$(docker inspect --format '{{.State.Status}}' "$(cat "$work/$1/cid")")" = exited
}

# requests_since STUB MARK: request log lines after line MARK.
requests_since() {
  sed -n "$(($2 + 1)),\$p" "$work/$1/requests.log"
}

mark() {
  wc -l <"$work/$1/requests.log" | tr -d ' '
}

expect_requests() {
  stub=$1 since=$2
  shift 2
  requests_since "$stub" "$since" >"$work/actual"
  : >"$work/expected"
  [ "$#" -eq 0 ] || printf '%s\n' "$@" >"$work/expected"
  cmp -s "$work/expected" "$work/actual" ||
    fail "unexpected management API requests; expected:
$(cat "$work/expected")
got:
$(cat "$work/actual")"
}

start_stub api
port=$(cat "$work/api/port")
uri=http://127.0.0.1:$port
put_body() {
  printf '{"hashing_algorithm": "rabbit_password_hashing_sha512", "name": "guest", "password": "%s", "tags": "administrator,monitoring"}' "$1"
}

# Rotation on the node that wins: the old password from the rabbitmqadmin file
# authenticates, the user is re-PUT with its tags and hashing algorithm kept,
# and the new password is copied into the rabbitmqadmin file.
server_password api old-0
new_node a guest old-0
start_updater a "$uri"
m=$(mark api)
first_render a guest rotated-1 'the first rotation' admin_password_is a rotated-1
expect_requests api "$m" \
  'GET /api/users/guest guest:old-0' \
  "PUT /api/users/guest guest:old-0 $(put_body rotated-1)"
test "$(cat "$work/api/password")" = rotated-1 || fail 'server password was not rotated'
grep -Fx 'username = guest' "$work/a/lib/.rabbitmqadmin.conf" >/dev/null ||
  fail "rabbitmqadmin username changed: $(cat "$work/a/lib/.rabbitmqadmin.conf")"

# A re-render with the password already in use makes no API call. Events are
# handled in order, so the next step's exact request list also covers this one.
m=$(mark api)
vault_render a guest rotated-1
sleep 2
expect_requests api "$m"
admin_password_matches a rotated-1

# Another node already rotated the server password: the old password gets 401,
# the new one is verified through /api/whoami, and the PUT is skipped.
server_password api rotated-2
vault_render a guest rotated-2
wait_for 'the peer-rotated update' admin_password_is a rotated-2
expect_requests api "$m" \
  'GET /api/users/guest guest:rotated-1' \
  'GET /api/whoami guest:rotated-2'

# Negative: neither the old nor the rendered password is accepted. The admin
# file must keep the old password and the sidecar must keep running.
server_password api someone-else
m=$(mark api)
vault_render a guest rotated-3
wait_for 'the rejected rotation' log_has a 'failed to GET /api/whoami with new password'
expect_requests api "$m" \
  'GET /api/users/guest guest:rotated-2' \
  'GET /api/whoami guest:rotated-3'
admin_password_matches a rotated-2
running a || fail "updater exited after a rejected password: $(logs a)"

# It recovers on the next render once the old password works again.
server_password api rotated-2
m=$(mark api)
vault_render a guest rotated-4
wait_for 'the recovered rotation' admin_password_is a rotated-4
expect_requests api "$m" \
  'GET /api/users/guest guest:rotated-2' \
  "PUT /api/users/guest guest:rotated-2 $(put_body rotated-4)"

# SIGTERM stops the sidecar cleanly.
docker stop --time 10 "$(cat "$work/a/cid")" >/dev/null
test "$(docker inspect --format '{{.State.ExitCode}}' "$(cat "$work/a/cid")")" = 0 ||
  fail "SIGTERM exit status: $(docker inspect --format '{{.State.ExitCode}}' "$(cat "$work/a/cid")")"

# Negative: the rendered default user differs from the rabbitmqadmin user.
# The sidecar stops without calling the API or touching the admin file.
server_password api old-0
new_node b guest old-0
start_updater b "$uri"
m=$(mark api)
first_render b intruder rotated-1 'the username-mismatch exit' exited b
log_has b 'exiting because usernames do not match' >/dev/null ||
  fail "no username mismatch diagnostic: $(logs b)"
expect_requests api "$m"
admin_password_matches b old-0
test "$(cat "$work/api/password")" = old-0 || fail 'server password changed on username mismatch'

# Negative: the rabbitmqadmin file is missing.
new_node c guest old-0
rm "$work/c/lib/.rabbitmqadmin.conf"
start_updater c "$uri"
m=$(mark api)
first_render c guest rotated-1 'the missing-admin-file exit' exited c
log_has c 'failed to load INI data source' >/dev/null || fail "no INI diagnostic: $(logs c)"
expect_requests api "$m"
test ! -e "$work/c/lib/.rabbitmqadmin.conf" || fail 'admin file was created'

# HTTPS management endpoint, trusted through the default --ca-file path.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=verity-test-ca \
  -keyout "$work/ca.key" -out "$work/ca.crt" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=verity-other-ca \
  -keyout "$work/other.key" -out "$work/other.crt" >/dev/null 2>&1
openssl req -new -newkey rsa:2048 -nodes -subj /CN=127.0.0.1 \
  -keyout "$work/tls.key" -out "$work/tls.csr" >/dev/null 2>&1
printf 'subjectAltName=IP:127.0.0.1\nextendedKeyUsage=serverAuth\n' >"$work/tls.ext"
openssl x509 -req -in "$work/tls.csr" -CA "$work/ca.crt" -CAkey "$work/ca.key" -CAcreateserial \
  -days 1 -extfile "$work/tls.ext" -out "$work/tls.crt" >/dev/null 2>&1
chmod 0644 "$work/ca.crt" "$work/other.crt"
start_stub tls "$work/tls.crt" "$work/tls.key"
tls_uri=https://127.0.0.1:$(cat "$work/tls/port")

# Positive: rotation over TLS.
server_password tls old-0
new_node d guest old-0
start_updater d "$tls_uri" "$work/ca.crt"
first_render d guest rotated-1 'the TLS rotation' admin_password_is d rotated-1
expect_requests tls 0 \
  'GET /api/users/guest guest:old-0' \
  "PUT /api/users/guest guest:old-0 $(put_body rotated-1)"

# Negative: a CA that did not sign the server certificate. No request reaches
# the handler and the admin file keeps the old password.
server_password tls old-0
m=$(mark tls)
new_node e guest old-0
start_updater e "$tls_uri" "$work/other.crt"
first_render e guest rotated-1 'the untrusted TLS failure' log_has e 'certificate signed by unknown authority'
expect_requests tls "$m"
admin_password_matches e old-0
test "$(cat "$work/tls/password")" = old-0 || fail 'server password changed through an untrusted TLS peer'
running e || fail "updater exited after a TLS failure: $(logs e)"

# Negative: HTTPS without the CA file stops at startup, before watching.
new_node f guest old-0
start_updater f "$tls_uri"
wait_for 'the missing-CA exit' exited f
log_has f 'failed to read CA file' >/dev/null || fail "no CA file diagnostic: $(logs f)"
test "$(docker inspect --format '{{.State.ExitCode}}' "$(cat "$work/f/cid")")" = 0 ||
  fail 'missing-CA exit status changed from upstream'

printf 'SMOKE PASS image=%s\n' "$image"
