#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
recipe=$here/../melange.yaml
container="verity-superset-test-$$"
volume="verity-superset-data-$$"
label="verity-w5e=superset"
work=$(mktemp -d)
secret="verity-test-secret-key-$$-0123456789abcdefghijklmnopqrstuvwxyz"
password="Verity-Admin-$$-pass"

# The expected release comes from the recipe, so a version bump needs no edit here.
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' "$recipe" | head -n 1)
[ -n "$expected_version" ] || { printf 'package version not found in %s\n' "$recipe" >&2; exit 1; }

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  docker logs "$container" >&2 2>/dev/null || true
  printf '%s\n' "$1" >&2
  exit 1
}

# Every CLI step runs as the image's non-root user with no capabilities and a
# read-only root filesystem. /tmp and the data volume are the only writable paths.
run() {
  docker run --rm --label "$label" --read-only --cap-drop ALL \
    --security-opt no-new-privileges \
    --tmpfs /tmp:exec,uid=65532,gid=65532,mode=1777 \
    -v "$volume:/app/superset_home" \
    -e SUPERSET_SECRET_KEY="$secret" "$@"
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /app ||
  fail 'unexpected working directory'
docker image inspect --format '{{json .Config.Cmd}}' "$image" | grep -F '"gunicorn"' >/dev/null ||
  fail 'default command is not gunicorn'
docker image inspect --format '{{json .Config.Cmd}}' "$image" | grep -F 'superset.app:create_app()' >/dev/null ||
  fail 'default command does not serve the Superset app'

# Negative: Superset refuses to start with the placeholder secret key.
if output=$(docker run --rm --label "$label" --read-only --tmpfs /tmp:exec,uid=65532,gid=65532 \
  "$image" superset version 2>&1); then
  fail 'Superset started without SUPERSET_SECRET_KEY'
fi
printf '%s\n' "$output" | grep -F 'Refusing to start due to insecure SECRET_KEY' >/dev/null ||
  fail 'missing secret key was not rejected for the expected reason'

# One named volume carries the SQLite database through every step below. It is
# initialised from the image's /app/superset_home, so it is owned by the
# non-root user.
docker volume create --label "$label" "$volume" >/dev/null

run "$image" superset version | grep -F "$expected_version" >/dev/null ||
  fail "unexpected Superset version, wanted $expected_version"

run "$image" superset db upgrade >"$work/upgrade.log" 2>&1 || {
  cat "$work/upgrade.log" >&2
  fail 'superset db upgrade failed on SQLite'
}
grep -F 'Migration scripts completed' "$work/upgrade.log" >/dev/null ||
  { cat "$work/upgrade.log" >&2; fail 'superset db upgrade did not report completed migrations'; }

run "$image" superset fab create-admin --username admin --firstname Verity --lastname Test \
  --email admin@example.com --password "$password" >"$work/admin.log" 2>&1 || {
  cat "$work/admin.log" >&2
  fail 'superset fab create-admin failed'
}
run "$image" superset init >"$work/init.log" 2>&1 || {
  cat "$work/init.log" >&2
  fail 'superset init failed'
}

# Native extensions behind SQL Lab results and image handling import under the
# fixed dependency set.
run "$image" /opt/superset/bin/python -c '
import io, msgpack, pandas, pyarrow, cryptography.fernet as f
from PIL import Image
key = f.Fernet.generate_key()
assert f.Fernet(key).decrypt(f.Fernet(key).encrypt(b"ok")) == b"ok"
buffer = io.BytesIO()
Image.new("RGB", (4, 4)).save(buffer, "PNG")
assert buffer.getvalue().startswith(b"\x89PNG")
assert msgpack.unpackb(msgpack.packb({"a": 1})) == {"a": 1}
assert pyarrow.table({"a": [1, 2]}).num_rows == 2
' || fail 'native Python extensions failed to import or run'

docker run --name "$container" --label "$label" -d --read-only --cap-drop ALL \
  --security-opt no-new-privileges \
  --tmpfs /tmp:exec,uid=65532,gid=65532,mode=1777 \
  -v "$volume:/app/superset_home" \
  -e SUPERSET_SECRET_KEY="$secret" -p 127.0.0.1::8088 "$image" >/dev/null
port=$(docker port "$container" 8088/tcp | awk -F: 'NR == 1 { print $2 }')
test -n "$port" || fail 'HTTP port was not published'
base="http://127.0.0.1:$port"

attempts=0
until curl --fail --silent --show-error --connect-timeout 1 --max-time 5 \
  "$base/health" >"$work/health.txt" 2>/dev/null; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 120 ] || fail 'Superset did not become ready'
  sleep 2
done
test "$(cat "$work/health.txt")" = OK || fail '/health did not return OK'

# The API requires authentication.
code=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 10 \
  "$base/api/v1/database/")
test "$code" = 401 || fail "unauthenticated API request returned $code, wanted 401"

# Negative: a wrong password is rejected.
code=$(curl --silent --output "$work/bad.json" --write-out '%{http_code}' --max-time 20 \
  -X POST -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"wrong-password","provider":"db"}' \
  "$base/api/v1/security/login")
test "$code" = 401 || fail "wrong password returned $code, wanted 401"

# The created admin can log in and receives a token.
code=$(curl --silent --output "$work/login.json" --write-out '%{http_code}' --max-time 20 \
  -X POST -H 'Content-Type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"$password\",\"provider\":\"db\"}" \
  "$base/api/v1/security/login")
test "$code" = 200 || fail "admin login returned $code, wanted 200"
grep -F '"access_token"' "$work/login.json" >/dev/null || fail 'login did not return an access token'

printf 'SMOKE PASS image=%s\n' "$image"
