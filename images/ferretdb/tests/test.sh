#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
expected_commit=$(sed -n 's/^[[:space:]]*source-commit: \([0-9a-f]\{40\}\)$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf '%s\n' 'package version not found' >&2; exit 1; }
[ -n "$expected_commit" ] || { printf '%s\n' 'source commit not found' >&2; exit 1; }
documentdb_index='ghcr.io/ferretdb/postgres-documentdb:17-0.107.0-ferretdb-2.7.0@sha256:2386795ec2aa7ae559304361979f1dc5708d383ee9020ae63dadc2940dfe58f7'
mongo_index='docker.io/library/mongo:8.0@sha256:d97fea17ccb8d004cd137be8dab54d70d0df11be69c9f422aefe4484c8414ab7'
suffix=$$
nobackend="verity-ferretdb-nobackend-$suffix"
backend="verity-ferretdb-postgres-$suffix"
proxy="verity-ferretdb-proxy-$suffix"
client="verity-ferretdb-client-$suffix"
mcp="verity-ferretdb-mcp-$suffix"
network="verity-ferretdb-network-$suffix"
state="verity-ferretdb-state-$suffix"
password="smoke-$suffix"
mcp_headers=$(mktemp)

cleanup() {
  docker rm -f "$nobackend" "$mcp" "$backend" "$proxy" "$client" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  docker volume rm "$state" >/dev/null 2>&1 || true
  rm -f "$mcp_headers"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

dump_logs() {
  for c in "$@"; do
    printf '%s\n' "--- logs: $c" >&2
    docker logs "$c" >&2 2>&1 || true
  done
}

wait_for_log() {
  container=$1
  pattern=$2
  i=0
  until docker logs "$container" 2>&1 | grep -Fq "$pattern"; do
    i=$((i + 1))
    if [ "$i" -ge 60 ]; then
      dump_logs "$container"
      fail "$container never logged '$pattern'"
    fi
    sleep 1
  done
}

# Fixture images are pulled by the per-platform child digest after verifying
# the pinned index bytes.
image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
pull_fixture() {
  index=$1
  raw=$(docker buildx imagetools inspect --raw "$index") || fail "cannot inspect $index"
  [ "sha256:$(printf '%s' "$raw" | sha256sum | cut -d' ' -f1)" = "${index#*@}" ] ||
    fail "fixture index digest mismatch for $index"
  digest=$(printf '%s' "$raw" |
    jq -r --arg arch "$image_arch" '
      [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
      | if length == 1 then .[0] else empty end') || fail "cannot resolve $index digest"
  case $digest in
    sha256:*) ;;
    *) fail "no unique linux/$image_arch image in $index" ;;
  esac
  ref=${index%%:*}@$digest
  docker pull --quiet --platform "linux/$image_arch" "$ref" >/dev/null || fail "cannot pull $ref"
  printf '%s\n' "$ref"
}

# OCI contract, matching the upstream production image.
entrypoint=$(docker image inspect -f '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' "$image")
[ "$entrypoint" = '["/ferretdb"] null' ] || fail "unexpected entrypoint/cmd: $entrypoint"
user=$(docker image inspect -f '{{.Config.User}}' "$image")
[ "$user" = 1000 ] || fail "image user is $user, want 1000"
workdir=$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")
[ "$workdir" = / ] || fail "unexpected working directory: $workdir"
env=$(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$image")
for want in FERRETDB_LISTEN_ADDR=:27017 FERRETDB_DEBUG_ADDR=:8088 FERRETDB_STATE_DIR=/state; do
  printf '%s\n' "$env" | grep -Fxq "$want" || fail "image environment lacks $want"
done

# Version reports the pinned release, source commit and package type.
version_out=$(timeout 60 docker run --rm --network none "$image" --version 2>&1) ||
  fail "--version failed: $version_out"
for want in "version: v$expected_version" "commit: $expected_commit" 'package: docker'; do
  printf '%s\n' "$version_out" | grep -Fxq "$want" || fail "--version lacks '$want': $version_out"
done

# Unknown flags are rejected.
if out=$(timeout 60 docker run --rm --network none "$image" --no-such-flag 2>&1); then
  fail 'ferretdb accepted an unknown flag'
fi
case $out in
  *'unknown flag --no-such-flag'*) ;;
  *) fail "unknown flag error not reported: $out" ;;
esac

# A state directory the process cannot write is fatal.
if out=$(timeout 60 docker run --rm --network none --user 65534:65534 "$image" 2>&1); then
  fail 'ferretdb started with an unwritable state directory'
fi
case $out in
  *'Failed to set up state provider'*) ;;
  *) fail "unwritable state directory error not reported: $out" ;;
esac

# Without a PostgreSQL backend the proxy still serves the MongoDB wire protocol
# and liveness, but readiness and ping must fail with a backend connection error.
docker run --name "$nobackend" -d --read-only --tmpfs /state:uid=1000,gid=1000 \
  -e FERRETDB_TELEMETRY=disable \
  -e FERRETDB_POSTGRESQL_URL=postgres://smoke@127.0.0.1:5432/postgres \
  -p 127.0.0.1::8088 "$image" >/dev/null
wait_for_log "$nobackend" 'Listening on TCP [::]:27017'
wait_for_log "$nobackend" 'Starting debug server'
debug_port=$(docker port "$nobackend" 8088/tcp | sed -n 's/^127\.0\.0\.1:\([0-9][0-9]*\)$/\1/p' | head -n1)
[ -n "$debug_port" ] || fail 'debug port is not published'
i=0
until [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$debug_port/debug/livez")" = 200 ]; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || { dump_logs "$nobackend"; fail 'livez did not return 200 without a backend'; }
  sleep 1
done
readyz=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$debug_port/debug/readyz")
[ "$readyz" = 500 ] || fail "readyz returned $readyz without a backend, want 500"
if ping_out=$(timeout 60 docker exec "$nobackend" /ferretdb ping \
  --listen-addr=127.0.0.1:27017 2>&1); then
  fail 'ping succeeded without a backend'
fi
case $ping_out in
  *'Ping failed'*'failed to connect to'*'127.0.0.1:5432'*) ;;
  *) fail "ping without a backend did not report the PostgreSQL connection failure: $ping_out" ;;
esac
[ "$(docker inspect -f '{{.State.Running}}' "$nobackend")" = true ] ||
  { dump_logs "$nobackend"; fail 'ferretdb exited without a backend'; }
docker stop "$nobackend" >/dev/null
code=$(docker inspect -f '{{.State.ExitCode}}' "$nobackend")
[ "$code" = 0 ] || { dump_logs "$nobackend"; fail "SIGTERM exit code $code, want 0"; }

# The MCP server is ported to go-sdk v1 by an image-local patch. It must
# initialize, list its tools, and return a tool error without a backend.
docker run --name "$mcp" -d --read-only --tmpfs /state:uid=1000,gid=1000 \
  -e FERRETDB_TELEMETRY=disable -p 127.0.0.1::8090 \
  "$image" --no-auth --listen-mcp-addr=:8090 >/dev/null
wait_for_log "$mcp" 'Starting MCP server on http://[::]:8090/mcp'
mcp_port=$(docker port "$mcp" 8090/tcp | sed -n 's/^127\.0\.0\.1:\([0-9][0-9]*\)$/\1/p' | head -n1)
[ -n "$mcp_port" ] || fail 'MCP port is not published'
mcp_post() {
  curl -sS -D "$mcp_headers" -X POST "http://127.0.0.1:$mcp_port/mcp" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    ${mcp_session:+-H "Mcp-Session-Id: $mcp_session"} \
    ${mcp_session:+-H 'MCP-Protocol-Version: 2025-06-18'} -d "$1"
}
mcp_session=
out=$(mcp_post '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"verity-smoke","version":"1"}}}') ||
  fail "MCP initialize failed: $out"
case $out in
  *'"serverInfo":{"name":"FerretDB","version":"v'"$expected_version"'"}'*) ;;
  *) fail "MCP initialize returned: $out" ;;
esac
mcp_session=$(awk -F': *' 'tolower($1) == "mcp-session-id" {print $2}' "$mcp_headers" | tr -d '\r')
[ -n "$mcp_session" ] || fail 'MCP initialize returned no session id'
mcp_post '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null ||
  fail 'MCP initialized notification failed'
out=$(mcp_post '{"jsonrpc":"2.0","id":2,"method":"tools/list"}') ||
  fail "MCP tools/list failed: $out"
for tool in find listCollections listDatabases; do
  case $out in
    *'"name":"'"$tool"'"'*) ;;
    *) fail "MCP tools/list lacks $tool: $out" ;;
  esac
done
out=$(mcp_post '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"listDatabases","arguments":{}}}') ||
  fail "MCP tools/call failed: $out"
case $out in
  *'"isError":true'*) ;;
  *) fail "MCP listDatabases without a backend did not return a tool error: $out" ;;
esac
case $out in
  *'failed to connect to'*'127.0.0.1:5432'*) ;;
  *) fail "MCP listDatabases did not report the PostgreSQL connection failure: $out" ;;
esac
docker rm -f "$mcp" >/dev/null

# With a DocumentDB backend, MongoDB clients can authenticate, write and read.
documentdb=$(pull_fixture "$documentdb_index")
mongo=$(pull_fixture "$mongo_index")
docker network create --internal "$network" >/dev/null
docker volume create "$state" >/dev/null
docker run --name "$backend" -d --network "$network" --network-alias postgres \
  -e POSTGRES_USER=smoke -e POSTGRES_PASSWORD="$password" -e POSTGRES_DB=postgres \
  "$documentdb" >/dev/null
i=0
until docker exec "$backend" pg_isready -h 127.0.0.1 -U smoke -d postgres >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 90 ] || { dump_logs "$backend"; fail 'DocumentDB backend did not become ready'; }
  sleep 1
done

start_proxy() {
  docker run --name "$proxy" -d --read-only --network "$network" --network-alias ferretdb \
    -v "$state:/state" -e FERRETDB_TELEMETRY=disable \
    -e FERRETDB_POSTGRESQL_URL="postgres://smoke:$password@postgres:5432/postgres" \
    "$image" >/dev/null
  i=0
  until docker exec "$proxy" /ferretdb ping --listen-addr=127.0.0.1:27017 >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -lt 90 ] || { dump_logs "$proxy" "$backend"; fail 'ferretdb ping did not succeed with a backend'; }
    sleep 1
  done
}
start_proxy

docker run --name "$client" -d --network "$network" --entrypoint sleep "$mongo" infinity >/dev/null
mongosh() {
  docker exec "$client" mongosh --quiet \
    "mongodb://smoke:$password@ferretdb:27017/smoke?authMechanism=SCRAM-SHA-256" --eval "$1"
}
out=$(mongosh 'db.items.insertOne({_id: "verity", n: 42}).acknowledged') ||
  { dump_logs "$proxy"; fail "insert failed: $out"; }
[ "$out" = true ] || fail "insert was not acknowledged: $out"
out=$(mongosh 'db.items.findOne({_id: "verity"}).n') || fail "find failed: $out"
[ "$out" = 42 ] || fail "find returned '$out', want 42"
out=$(mongosh 'db.adminCommand({buildInfo: 1}).ferretdb.version') || fail "buildInfo failed: $out"
[ "$out" = "v$expected_version" ] || fail "buildInfo reported '$out', want v$expected_version"

# Wrong credentials are rejected.
if out=$(docker exec "$client" mongosh --quiet \
  "mongodb://smoke:wrong@ferretdb:27017/smoke?authMechanism=SCRAM-SHA-256" \
  --eval 'db.items.countDocuments()' 2>&1); then
  fail "wrong password was accepted: $out"
fi
case $out in
  *[Aa]uthentication*) ;;
  *) fail "wrong password did not fail authentication: $out" ;;
esac

# Data lives in PostgreSQL and survives a proxy restart; state stays writable.
docker stop "$proxy" >/dev/null
code=$(docker inspect -f '{{.State.ExitCode}}' "$proxy")
[ "$code" = 0 ] || { dump_logs "$proxy"; fail "SIGTERM exit code $code, want 0"; }
docker rm "$proxy" >/dev/null
start_proxy
out=$(mongosh 'db.items.countDocuments({n: 42})') || fail "count after restart failed: $out"
[ "$out" = 1 ] || fail "document count after restart is '$out', want 1"
docker exec "$proxy" /ferretdb --version >/dev/null || fail 'version failed in running container'
docker run --rm --network none -v "$state:/state:ro" --entrypoint /bin/sh "$mongo" \
  -c 'test -s /state/state.json' || fail 'state.json was not written to /state'

printf 'SMOKE PASS image=%s\n' "$image"
