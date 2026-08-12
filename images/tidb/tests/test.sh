#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-tidb-test-$$"
negative="verity-tidb-negative-$$"
version="verity-tidb-version-$$"
volume="verity-tidb-data-$$"
negative_log=$(mktemp)

cleanup() {
  docker rm -f "$container" "$negative" "$version" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
  rm -f "$negative_log"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  docker logs "$container" >&2 2>/dev/null || true
  printf '%s\n' "$1" >&2
  exit 1
}

test "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532
test "$(docker image inspect "$image" --format '{{.Config.WorkingDir}}')" = /var/lib/tidb
test "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/tidb-server"]'

docker create --name "$version" --cpus 4 --network none --entrypoint /bin/sh "$image" -c '
  test -s /usr/share/licenses/verity-tidb/LICENSE
  exec /usr/bin/tidb-server -V
' >/dev/null
docker update --cpus 4 "$version" >/dev/null
version_output=$(docker start -a "$version" 2>&1)
printf '%s\n' "$version_output" | grep -F 'Release Version: v9.0.0-beta.1' >/dev/null \
  || fail 'TiDB version check failed'
printf '%s\n' "$version_output" | grep -F 'Git Commit Hash: 7aff918dcbfa6facf2adef9ade9961c40f217421' >/dev/null \
  || fail 'TiDB source commit check failed'
docker rm "$version" >/dev/null

docker volume create "$volume" >/dev/null

mysql_roundtrip() {
  python3 - "$sql_port" "$1" "$2" <<'PY'
import socket
import struct
import sys

port = int(sys.argv[1])
mode = sys.argv[2]
marker = sys.argv[3]


def read_exact(connection, size):
    data = b""
    while len(data) < size:
        chunk = connection.recv(size - len(data))
        if not chunk:
            raise RuntimeError("unexpected MySQL connection close")
        data += chunk
    return data


def read_packet(connection):
    header = read_exact(connection, 4)
    return header[3], read_exact(connection, int.from_bytes(header[:3], "little"))


def write_packet(connection, sequence, payload):
    connection.sendall(len(payload).to_bytes(3, "little") + bytes([sequence]) + payload)


def length_encoded(payload, offset=0):
    first = payload[offset]
    if first < 0xFB:
        return first, offset + 1
    sizes = {0xFC: 2, 0xFD: 3, 0xFE: 8}
    size = sizes[first]
    start = offset + 1
    return int.from_bytes(payload[start : start + size], "little"), start + size


def check_error(payload):
    if payload[0] == 0xFF:
        code = int.from_bytes(payload[1:3], "little")
        message = payload[9:] if payload[3:4] == b"#" else payload[3:]
        raise RuntimeError(f"MySQL error {code}: {message.decode(errors='replace')}")


def query(connection, statement):
    write_packet(connection, 0, b"\x03" + statement.encode())
    _, payload = read_packet(connection)
    check_error(payload)
    if payload[0] == 0x00:
        return []
    columns, _ = length_encoded(payload)
    for _ in range(columns):
        read_packet(connection)
    read_packet(connection)
    rows = []
    while True:
        _, payload = read_packet(connection)
        if payload[0] == 0xFE and len(payload) < 9:
            return rows
        row = []
        offset = 0
        for _ in range(columns):
            length, offset = length_encoded(payload, offset)
            row.append(payload[offset : offset + length].decode())
            offset += length
        rows.append(row)


with socket.create_connection(("127.0.0.1", port), timeout=5) as connection:
    _, greeting = read_packet(connection)
    position = greeting.index(0, 1) + 1 + 4 + 8 + 1
    capabilities = int.from_bytes(greeting[position : position + 2], "little")
    capabilities |= int.from_bytes(greeting[position + 5 : position + 7], "little") << 16
    requested = 0x00000001 | 0x00000004 | 0x00000200 | 0x00002000 | 0x00008000 | 0x00080000
    response_flags = capabilities & requested
    response = struct.pack("<IIB23x", response_flags, 16 * 1024 * 1024, 45)
    response += b"root\0\0"
    if response_flags & 0x00080000:
        response += b"mysql_native_password\0"
    write_packet(connection, 1, response)
    sequence, payload = read_packet(connection)
    if payload[0] == 0xFE and len(payload) > 1:
        write_packet(connection, sequence + 1, b"")
        _, payload = read_packet(connection)
    check_error(payload)
    if payload[0] != 0x00:
        raise RuntimeError("unexpected MySQL authentication response")

    if mode == "write":
        query(connection, "CREATE DATABASE IF NOT EXISTS verity_smoke")
        query(
            connection,
            "CREATE TABLE IF NOT EXISTS verity_smoke.persistence "
            "(id BIGINT PRIMARY KEY, value VARCHAR(64))",
        )
        query(connection, f"REPLACE INTO verity_smoke.persistence VALUES (1, '{marker}')")
    else:
        rows = query(connection, "SELECT value FROM verity_smoke.persistence WHERE id = 1")
        if rows != [[marker]]:
            raise RuntimeError(f"persisted row mismatch: {rows!r}")
PY
}

start() {
  docker create --name "$container" --cpus 4 \
    -v "$volume:/var/lib/tidb" \
    -p 127.0.0.1::4000 -p 127.0.0.1::10080 \
    "$image" \
    --store=unistore \
    --path=/var/lib/tidb \
    --host=0.0.0.0 \
    --status-host=0.0.0.0 >/dev/null
  docker update --cpus 4 "$container" >/dev/null
  docker start "$container" >/dev/null

  sql_port=$(docker port "$container" 4000/tcp | awk -F: 'NR == 1 { print $2 }')
  status_port=$(docker port "$container" 10080/tcp | awk -F: 'NR == 1 { print $2 }')
  [ -n "$sql_port" ] && [ -n "$status_port" ] \
    || fail 'SQL and status ports were not published'

  attempts=0
  until status=$(curl -fsS --max-time 2 "http://127.0.0.1:$status_port/status"); do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 60 ] || fail 'TiDB did not become ready'
    sleep 1
  done
  printf '%s\n' "$status" | grep -F '"connections"' >/dev/null \
    || fail 'TiDB status response did not contain connection state'
}

start
marker="verity-$$"
mysql_roundtrip write "$marker" || fail 'could not write TiDB persistence marker'

sql_probe=$(curl --verbose --connect-timeout 2 --max-time 3 "http://127.0.0.1:$sql_port/" 2>&1 || true)
printf '%s\n' "$sql_probe" | grep -Fq 'Connected to 127.0.0.1' \
  || fail 'MySQL listener is not accepting connections on port 4000'
docker exec "$container" /bin/sh -c \
  'test -n "$(find /var/lib/tidb -mindepth 1 -maxdepth 1 -print -quit)"' \
  || fail 'TiDB did not write persistent state'

docker create --name "$negative" --cpus 4 --network "container:$container" \
  "$image" --store=unistore --path=/tmp/tidb-negative --host=0.0.0.0 --status-host=0.0.0.0 >/dev/null
docker update --cpus 4 "$negative" >/dev/null
if docker start -a "$negative" >"$negative_log" 2>&1; then
  fail 'second TiDB server unexpectedly reused occupied ports'
fi
grep -F 'address already in use' "$negative_log" >/dev/null \
  || fail 'occupied port did not return the expected bind error'
docker rm "$negative" >/dev/null

docker rm -f "$container" >/dev/null
start
mysql_roundtrip read "$marker" || fail 'TiDB row did not survive restart'
docker exec "$container" /bin/sh -c \
  'test -n "$(find /var/lib/tidb -mindepth 1 -maxdepth 1 -print -quit)"' \
  || fail 'TiDB state did not survive restart'

printf 'SMOKE PASS image=%s\n' "$image"
