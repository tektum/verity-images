#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
config="$here/../apko.yaml"
version=$(sed -n 's/^    - json-server=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
id=$$
server="verity-json-server-$id"
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  docker logs "$server" 2>&1 | tail -n 30 >&2 || true
  exit 1
}

cleanup() {
  docker rm -f "$server" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

# Run a request from inside the server's network namespace with the image's own
# node, so the test needs no host port or client image. Prints "STATUS BODY".
request() {
  docker run --rm --network "container:$server" --entrypoint /usr/bin/node "$image" \
    -e '
const [method, path, body] = process.argv.slice(1);
const init = { method };
if (body) { init.body = body; init.headers = { "content-type": "application/json" }; }
fetch("http://127.0.0.1:3000" + path, init)
  .then(async (r) => { process.stdout.write(r.status + " " + await r.text()); })
  .catch((e) => { console.error(e.message); process.exit(1); });
' "$@"
}

[ -n "$version" ] || fail 'could not read the pinned json-server version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/tini","--","/usr/bin/node","/usr/local/lib/node_modules/json-server/lib/cli/bin.js"]' ||
  fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = \
  '["--host","0.0.0.0","--port","3000","db.json"]' || fail 'unexpected command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /data ||
  fail 'unexpected working directory'

docker run --rm --network none "$image" --version >"$work/version" 2>&1 ||
  fail 'version failed'
grep -Fx "$version" "$work/version" >/dev/null ||
  fail "version does not report $version: $(cat "$work/version")"

mkdir -p "$work/data" "$work/bad"
cp "$here/db.json" "$work/data/db.json"
printf '{"posts": [\n' >"$work/bad/db.json"
chmod 777 "$work/data" "$work/bad"
chmod 666 "$work/data/db.json" "$work/bad/db.json"

# Negative: a malformed database exits non-zero with a readable error.
rc=0
timeout 30 docker run --rm --name "$server-bad" --network none -v "$work/bad:/data" "$image" \
  >"$work/malformed" 2>&1 || rc=$?
docker rm -f "$server-bad" >/dev/null 2>&1 || true
{ test "$rc" -ne 0 && test "$rc" -ne 124; } || fail 'malformed database unexpectedly started'
grep -F 'Malformed JSON in file: db.json' "$work/malformed" >/dev/null ||
  fail "malformed database diagnostic is missing: $(cat "$work/malformed")"

# Default command on a read-only root with no capabilities; only /data is writable.
docker run -d --name "$server" --read-only --cap-drop=ALL --tmpfs /tmp:rw,mode=1777 \
  -v "$work/data:/data" "$image" >/dev/null

ready=false
i=0
while [ "$i" -lt 30 ]; do
  if request GET /posts >"$work/posts" 2>/dev/null; then
    ready=true
    break
  fi
  i=$((i + 1))
  sleep 1
done
"$ready" || fail 'server did not become ready'

check() {
  python3 - "$@" <<'PY' || fail "unexpected response for $1"
import json, sys
label, raw, want_status, expr = sys.argv[1:5]
status, _, body = open(raw).read().partition(" ")
assert status == want_status, (label, status, body)
data = json.loads(body)
assert eval(expr, {"data": data}), (label, data)
PY
}

check 'GET /posts' "$work/posts" 200 \
  'data == [{"id": 1, "title": "verity fixture one", "author": "alice"}, {"id": 2, "title": "verity fixture two", "author": "bob"}]'

request GET '/posts?author=bob' >"$work/filter"
check 'GET /posts?author=bob' "$work/filter" 200 '[p["id"] for p in data] == [2]'

request GET '/posts/1?_embed=comments' >"$work/embed"
check 'GET /posts/1?_embed=comments' "$work/embed" 200 \
  'data["title"] == "verity fixture one" and [c["body"] for c in data["comments"]] == ["first"]'

request GET /profile >"$work/profile"
check 'GET /profile' "$work/profile" 200 'data == {"name": "verity"}'

request GET /posts/99 >"$work/missing"
check 'GET /posts/99' "$work/missing" 404 'data == {}'

request POST /posts '{"title": "created by smoke test", "author": "carol"}' >"$work/create"
check 'POST /posts' "$work/create" 201 'data == {"id": 3, "title": "created by smoke test", "author": "carol"}'

request GET /posts/3 >"$work/created"
check 'GET /posts/3' "$work/created" 200 'data["author"] == "carol"'

# Writes are persisted to the database file in the mounted volume.
i=0
until python3 -c '
import json, sys
db = json.load(open(sys.argv[1]))
sys.exit(0 if any(p.get("author") == "carol" for p in db["posts"]) else 1)
' "$work/data/db.json" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 10 ] || fail 'created record was not persisted to db.json'
  sleep 1
done

docker logs "$server" 2>&1 | grep -E 'POST /posts.*201' >/dev/null ||
  fail 'request log line is missing'

# The server keeps running and stops cleanly on SIGTERM through tini.
docker inspect --format '{{.State.Running}}' "$server" | grep -Fx true >/dev/null ||
  fail 'server exited after serving requests'
docker stop -t 10 "$server" >/dev/null
rc=$(docker inspect --format '{{.State.ExitCode}}' "$server")
case "$rc" in
  0 | 143) ;;
  *) fail "server exit code $rc after SIGTERM" ;;
esac

printf 'SMOKE PASS image=%s\n' "$image"
