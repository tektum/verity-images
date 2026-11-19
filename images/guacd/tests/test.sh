#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
config="$(dirname "$0")/../apko.yaml"
version=$(sed -n 's/^    - guacamole-server=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
server="verity-guacd-server-$$"
work=$(mktemp -d)

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$server" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail 'could not read the pinned guacamole-server version'

# OCI contract: non-root, foreground, all interfaces, IANA port 4822.
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/sbin/guacd","-f","-b","0.0.0.0"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = \
  '["-l","4822","-L","info"]' || fail 'unexpected command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'
# APKO cannot declare EXPOSE; the port contract is the default command.
test "$(docker image inspect --format '{{json .Config.ExposedPorts}}' "$image")" = null ||
  fail 'unexpected exposed ports'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" >"$work/env"
grep -Fx 'LC_ALL=C.UTF-8' "$work/env" >/dev/null || fail "LC_ALL is not C.UTF-8: $(cat "$work/env")"

docker run --rm --network none "$image" -v >"$work/version" 2>&1 ||
  fail "guacd -v failed: $(cat "$work/version")"
grep -Fx "Guacamole proxy daemon (guacd) version $version" "$work/version" >/dev/null ||
  fail "guacd -v does not report $version: $(cat "$work/version")"

# Negative: an invalid log level is rejected at startup.
if docker run --rm --network none "$image" -L bogus >"$work/badlevel" 2>&1; then
  fail 'guacd accepted an invalid log level'
fi
grep -F 'Invalid log level' "$work/badlevel" >/dev/null ||
  fail "invalid log level was not reported: $(cat "$work/badlevel")"

docker run -d --name "$server" -p 127.0.0.1::4822 "$image" >/dev/null
attempts=0
until docker logs "$server" 2>&1 | grep -F 'Listening on host 0.0.0.0, port 4822' >/dev/null; do
  [ "$(docker inspect --format '{{.State.Running}}' "$server")" = true ] ||
    fail "guacd exited: $(docker logs "$server" 2>&1)"
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || fail "guacd did not listen on 0.0.0.0:4822: $(docker logs "$server" 2>&1)"
  sleep 1
done
docker top "$server" -o pid,uid,args >"$work/top"
awk 'NR > 1 && $2 != 65532 { bad = 1 } END { exit bad }' "$work/top" ||
  fail "guacd is not running as uid 65532: $(cat "$work/top")"
port=$(docker port "$server" 4822/tcp | sed -n '1s/.*://p')
[ -n "$port" ] || fail 'container port 4822 is not published'

cat >"$work/client.py" <<'PY'
import socket
import sys


def encode(*elements):
    return ",".join(f"{len(e)}.{e}" for e in elements) + ";"


def parse(data):
    elements, pos = [], 0
    while True:
        dot = data.index(".", pos)
        length = int(data[pos:dot])
        elements.append(data[dot + 1 : dot + 1 + length])
        term = data[dot + 1 + length]
        pos = dot + 2 + length
        if term == ";":
            return elements
        if term != ",":
            raise ValueError(f"bad terminator {term!r}")


port, mode, payload = int(sys.argv[1]), sys.argv[2], sys.argv[3]
sock = socket.create_connection(("127.0.0.1", port), timeout=10)
sock.sendall((encode("select", payload) if mode == "select" else payload).encode())
data = b""
try:
    sock.settimeout(10 if mode == "select" else 3)
    while not data.endswith(b";"):
        chunk = sock.recv(65536)
        if not chunk:
            break
        data += chunk
except socket.timeout:
    pass
text = data.decode()
if not text:
    print("NO-REPLY")
else:
    print("\n".join(parse(text)))
PY

# Each promised protocol plugin loads and answers select with args.
for protocol in vnc rdp ssh telnet; do
  python3 "$work/client.py" "$port" select "$protocol" >"$work/$protocol" ||
    fail "$protocol select failed: $(cat "$work/$protocol")"
  test "$(sed -n 1p "$work/$protocol")" = args ||
    fail "$protocol select did not return args: $(cat "$work/$protocol")"
  test "$(sed -n 2p "$work/$protocol")" = VERSION_1_5_0 ||
    fail "$protocol args lack the protocol version: $(cat "$work/$protocol")"
  grep -Fx hostname "$work/$protocol" >/dev/null ||
    fail "$protocol args lack hostname: $(cat "$work/$protocol")"
done
grep -Fx enable-printing "$work/rdp" >/dev/null || fail 'rdp args lack enable-printing'
grep -Fx font-name "$work/ssh" >/dev/null || fail 'ssh args lack font-name'
grep -Fx encodings "$work/vnc" >/dev/null || fail 'vnc args lack encodings'

# Negative: unknown protocols (including the unpackaged kubernetes plugin)
# get no args and are logged as not installed.
for protocol in bogus kubernetes; do
  python3 "$work/client.py" "$port" unknown "$(printf '6.select,%s.%s;' "${#protocol}" "$protocol")" \
    >"$work/$protocol" || fail "$protocol probe failed"
  test "$(cat "$work/$protocol")" = NO-REPLY ||
    fail "guacd answered select $protocol: $(cat "$work/$protocol")"
  docker logs "$server" 2>&1 |
    grep -F "Support for protocol \"$protocol\" is not installed" >/dev/null ||
    fail "guacd did not reject protocol $protocol: $(docker logs "$server" 2>&1)"
done

# Negative: a malformed instruction gets no args.
python3 "$work/client.py" "$port" raw '5.select,3.vnc;' >"$work/malformed" ||
  fail 'malformed probe failed'
test "$(cat "$work/malformed")" = NO-REPLY ||
  fail "guacd answered a malformed instruction: $(cat "$work/malformed")"

# The daemon survives the rejected connections.
python3 "$work/client.py" "$port" select vnc >"$work/vnc-after" ||
  fail "vnc select after rejections failed: $(cat "$work/vnc-after")"
test "$(sed -n 1p "$work/vnc-after")" = args ||
  fail "guacd stopped serving after rejections: $(cat "$work/vnc-after")"

# SIGTERM to PID 1 stops guacd cleanly.
docker stop --time 10 "$server" >/dev/null
test "$(docker inspect --format '{{.State.ExitCode}}' "$server")" = 0 ||
  fail "guacd exited non-zero on SIGTERM: $(docker logs "$server" 2>&1 | tail -5)"

printf 'SMOKE PASS image=%s\n' "$image"
