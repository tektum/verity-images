#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
suffix=$$
server=verity-rethinkdb-$suffix
volume=verity-rethinkdb-data-$suffix
work=$(mktemp -d)

cleanup() {
  docker rm -f "$server" >/dev/null 2>&1 || true
  docker volume rm "$volume" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  docker logs "$server" >&2 2>&1 || true
  exit 1
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/rethinkdb"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = \
  '["--bind","all","--directory","/data/rethinkdb_data"]' || fail 'unexpected command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /data ||
  fail 'unexpected working directory'
docker image inspect --format '{{json .Config.Volumes}}' "$image" | grep -F '"/data"' >/dev/null ||
  fail '/data is not a declared volume'

docker run --rm --network none "$image" --version | grep -E '^rethinkdb 2\.4\.[0-9]+' >/dev/null ||
  fail 'rethinkdb --version output is missing'

# Negative: an invalid option value must exit non-zero with a readable error.
if docker run --rm --network none "$image" --cache-size not-a-number >"$work/bad" 2>&1; then
  fail 'invalid --cache-size unexpectedly succeeded'
fi
grep -Fi 'cache-size' "$work/bad" >/dev/null || fail 'invalid option error does not name the option'

docker volume create "$volume" >/dev/null

start_server() {
  docker run -d --name "$server" -p 127.0.0.1::28015 -p 127.0.0.1::8080 \
    -v "$volume:/data" "$image" >/dev/null
  i=0
  until docker logs "$server" 2>&1 | grep -F 'Server ready' >/dev/null; do
    i=$((i + 1))
    if [ "$i" -gt 60 ]; then
      fail 'rethinkdb did not report Server ready'
    fi
    sleep 1
  done
  driver_port=$(docker port "$server" 28015/tcp | head -n 1 | sed 's/.*://')
  http_port=$(docker port "$server" 8080/tcp | head -n 1 | sed 's/.*://')
}

# Minimal stdlib client for the ReQL V1_0 wire protocol (SCRAM-SHA-256
# handshake), run on the host so the test installs no driver package.
cat >"$work/reql.py" <<'PY'
import base64, hashlib, hmac, json, os, socket, struct, sys

host, port, mode = sys.argv[1], int(sys.argv[2]), sys.argv[3]
user = sys.argv[4] if len(sys.argv) > 4 else "admin"


def recv_null(sock):
    data = b""
    while not data.endswith(b"\0"):
        chunk = sock.recv(1)
        if not chunk:
            raise SystemExit("connection closed during handshake")
        data += chunk
    return json.loads(data[:-1])


def connect():
    sock = socket.create_connection((host, port), timeout=20)
    sock.sendall(struct.pack("<I", 0x34C2BDC3))
    nonce = base64.b64encode(os.urandom(18)).decode()
    first_bare = f"n={user},r={nonce}"
    sock.sendall(json.dumps({"protocol_version": 0, "authentication_method": "SCRAM-SHA-256",
                             "authentication": "n,," + first_bare}).encode() + b"\0")
    hello = recv_null(sock)
    if not hello.get("success"):
        raise SystemExit(f"handshake rejected: {hello}")
    server_first = recv_null(sock)
    if not server_first.get("success"):
        raise SystemExit(f"auth rejected: {server_first.get('error')}")
    fields = dict(item.split("=", 1) for item in server_first["authentication"].split(","))
    salted = hashlib.pbkdf2_hmac("sha256", b"", base64.b64decode(fields["s"]), int(fields["i"]))
    client_key = hmac.new(salted, b"Client Key", hashlib.sha256).digest()
    without_proof = f"c=biws,r={fields['r']}"
    auth_message = f"{first_bare},{server_first['authentication']},{without_proof}".encode()
    signature = hmac.new(hashlib.sha256(client_key).digest(), auth_message, hashlib.sha256).digest()
    proof = base64.b64encode(bytes(a ^ b for a, b in zip(client_key, signature))).decode()
    sock.sendall(json.dumps({"authentication": f"{without_proof},p={proof}"}).encode() + b"\0")
    final = recv_null(sock)
    if not final.get("success"):
        raise SystemExit(f"auth rejected: {final.get('error')}")
    return hello["server_version"], sock


token = 0


def run(sock, term):
    global token
    token += 1
    body = json.dumps([1, term, {}]).encode()
    sock.sendall(struct.pack("<QI", token, len(body)) + body)
    header = b""
    while len(header) < 12:
        chunk = sock.recv(12 - len(header))
        if not chunk:
            raise SystemExit("connection closed while reading a response header")
        header += chunk
    got, size = struct.unpack("<QI", header)
    payload = b""
    while len(payload) < size:
        chunk = sock.recv(size - len(payload))
        if not chunk:
            raise SystemExit("connection closed while reading a response body")
        payload += chunk
    response = json.loads(payload)
    if got != token:
        raise SystemExit(f"token mismatch {got} != {token}")
    return response


def ok(response, what):
    if response["t"] not in (1, 2):
        raise SystemExit(f"{what} failed: {response}")
    return response["r"][0] if response["t"] == 1 else response["r"]


DB = [14, ["smoke"]]
TABLE = [15, [DB, "docs"]]

if mode == "write":
    version, sock = connect()
    print(f"server_version={version}")
    ok(run(sock, [57, ["smoke"]]), "db_create")
    ok(run(sock, [60, [DB, "docs"]]), "table_create")
    inserted = ok(run(sock, [56, [TABLE, [2, [{"id": "a", "n": 1, "tag": "alpha"},
                                               {"id": "b", "n": 2, "tag": "beta"},
                                               {"id": "c", "n": 3, "tag": "alpha"}]]]]), "insert")
    assert inserted["inserted"] == 3, inserted
    doc = ok(run(sock, [16, [TABLE, "b"]]), "get")
    assert doc == {"id": "b", "n": 2, "tag": "beta"}, doc
    # filter(tag == "alpha").count() via ReQL FUNC/VAR terms.
    alpha = ok(run(sock, [43, [[39, [TABLE, [69, [[2, [1]], [17, [[170, [[10, [1]], "tag"]], "alpha"]]]]]]]]), "filter count")
    assert alpha == 2, alpha
    # Negative: a query on a missing table returns a runtime error, not data.
    missing = run(sock, [16, [[15, [DB, "missing"]], "x"]])
    assert missing["t"] == 18 and "does not exist" in missing["r"][0], missing
    # r.json parses UTF-16 surrogate pairs and rejects lone surrogates without
    # taking the server down (CVE-2026-24810 is in the legacy cJSON path only).
    emoji = ok(run(sock, [98, ['"' + '\\ud83d\\ude00' * 512 + '"']]), "json surrogates")
    assert emoji == "\U0001F600" * 512, "surrogate pair decode mismatch"
    lone = run(sock, [98, ['"' + '\\ud800' * 4096 + '"']])
    assert lone["t"] in (1, 18), lone
    ok(run(sock, [16, [TABLE, "a"]]), "get after json probes")
    print("write ok")
elif mode == "read":
    version, sock = connect()
    # table.wait() blocks until the reloaded table is ready for reads.
    ok(run(sock, [177, [TABLE]]), "table wait after restart")
    docs = ok(run(sock, [16, [TABLE, "c"]]), "get after restart")
    assert docs == {"id": "c", "n": 3, "tag": "alpha"}, docs
    count = ok(run(sock, [43, [TABLE]]), "count after restart")
    assert count == 3, count
    print("read ok")
elif mode == "baduser":
    connect()
    raise SystemExit("unknown user was accepted")
PY

reql() {
  python3 "$work/reql.py" 127.0.0.1 "$driver_port" "$@"
}

start_server

# The admin console is served on 8080.
python3 -c "import sys, urllib.request; print(urllib.request.urlopen(sys.argv[1], timeout=20).read().decode())" \
  "http://127.0.0.1:$http_port/" >"$work/admin.html" || fail 'admin console request failed'
grep -F '<title>RethinkDB Administration Console</title>' "$work/admin.html" >/dev/null ||
  fail 'admin console HTML is missing'

reql write >"$work/write" 2>&1 || { cat "$work/write" >&2; fail 'ReQL create/insert/query failed'; }
grep -E '^server_version=2\.4\.[0-9]+' "$work/write" >/dev/null || fail 'ReQL handshake reported an unexpected version'
grep -Fx 'write ok' "$work/write" >/dev/null || fail 'ReQL write phase did not complete'

# Negative: an unknown user must be rejected during the SCRAM handshake.
if reql baduser nobody >"$work/baduser" 2>&1; then
  fail 'unknown user was accepted'
fi
grep -F 'auth rejected' "$work/baduser" >/dev/null || fail 'unknown user error is not an auth rejection'

# SIGTERM must shut the server down cleanly.
docker stop -t 30 "$server" >/dev/null
test "$(docker inspect --format '{{.State.ExitCode}}' "$server")" = 0 ||
  fail 'rethinkdb did not exit 0 on SIGTERM'
docker logs "$server" 2>&1 | grep -F 'Shutting down' >/dev/null || fail 'shutdown was not logged'
docker rm "$server" >/dev/null

# Persistence: the data written before the restart must still be there.
start_server
reql read >"$work/read" 2>&1 || { cat "$work/read" >&2; fail 'ReQL read after restart failed'; }
grep -Fx 'read ok' "$work/read" >/dev/null || fail 'data did not persist across restart'

printf 'SMOKE PASS image=%s\n' "$image"
