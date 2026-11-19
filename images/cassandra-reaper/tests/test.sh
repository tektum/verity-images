#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
prefix="verity-cassandra-reaper-test-$$"
container=$prefix-main

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  for c in $(docker ps -aq --filter "name=^$prefix-"); do
    docker logs --tail 60 "$c" >&2 2>&1 || true
  done
  exit 1
}

cleanup() {
  docker ps -aq --filter "name=^$prefix-" | xargs -r docker rm -f >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

inspect() {
  docker image inspect -f "$1" "$image"
}

# --- OCI contract -----------------------------------------------------------
[ "$(inspect '{{.Config.User}}')" = 1001 ] || fail "unexpected OCI user: $(inspect '{{.Config.User}}')"
[ "$(inspect '{{json .Config.Entrypoint}} {{json .Config.Cmd}}')" = '["/usr/local/bin/entrypoint.sh"] ["cassandra-reaper"]' ] ||
  fail "unexpected OCI entrypoint/cmd: $(inspect '{{json .Config.Entrypoint}} {{json .Config.Cmd}}')"
volumes=$(inspect '{{json .Config.Volumes}}')
[ "$volumes" = '{"/etc/cassandra-reaper/config":{},"/etc/cassandra-reaper/shiro":{},"/var/lib/cassandra-reaper":{}}' ] ||
  fail "unexpected OCI volumes: $volumes"
env=$(inspect '{{range .Config.Env}}{{println .}}{{end}}')
for want in \
  REAPER_STORAGE_TYPE=memory \
  REAPER_SERVER_APP_PORT=8080 \
  REAPER_SERVER_ADMIN_PORT=8081 \
  REAPER_AUTH_ENABLED=true \
  REAPER_TMP_DIRECTORY=/var/tmp/cassandra-reaper \
  REAPER_MEMORY_STORAGE_DIRECTORY=/var/lib/cassandra-reaper/storage \
  REAPER_REPAIR_PARALELLISM=DATACENTER_AWARE \
  'REAPER_LOGGING_APPENDERS_CONSOLE_LOG_FORMAT="%-6level [%d] [%t] %logger{5} - %msg %n"' \
  'REAPER_JMX_PORTS={}' \
  JAVA_OPTS=; do
  printf '%s\n' "$env" | grep -qxF -- "$want" || fail "missing upstream env default: $want"
done

http_status() {
  # HTTP status of a request made with the image's curl from inside the container (000: no answer).
  c=$1
  shift
  docker exec "$c" curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" || true
}

# fetch CONTAINER CURL-ARGS...: response body of a successful request made inside the container.
fetch() {
  c=$1
  shift
  docker exec "$c" curl -fsS --max-time 5 "$@"
}

wait_ready() {
  c=$1
  port=$2
  i=0
  until fetch "$c" -o /dev/null "http://127.0.0.1:$port/healthcheck" 2>/dev/null; do
    i=$((i + 1))
    [ "$(docker inspect -f '{{.State.Running}}' "$c")" = true ] || fail "$c exited before becoming healthy"
    [ "$i" -lt 120 ] || fail "$c admin /healthcheck on :$port never became ready"
    sleep 1
  done
}

# --- Main run: memory storage, overridden app port, no network ---------------
docker run -d --name "$container" --network none \
  -e REAPER_STORAGE_TYPE=memory \
  -e REAPER_AUTH_ENABLED=false \
  -e REAPER_SERVER_APP_PORT=18080 \
  -e REAPER_HEAP_SIZE=256m \
  "$image" >/dev/null || fail 'docker run failed'

wait_ready "$container" 8081

health=$(fetch "$container" http://127.0.0.1:8081/healthcheck) || fail 'healthcheck request failed'
printf '%s\n' "$health" | grep -Eq '"reaper" *: *\{ *"healthy" *: *true' || fail "reaper health check missing or unhealthy: $health"

# configure-server.sh must have moved the application connector to the overridden port.
status=$(http_status "$container" http://127.0.0.1:18080/ping)
[ "$status" = 204 ] || [ "$status" = 200 ] || fail "app /ping on overridden port 18080 returned '$status'"
if fetch "$container" -o /dev/null http://127.0.0.1:8080/ping 2>/dev/null; then
  fail 'app still listens on default port 8080 despite REAPER_SERVER_APP_PORT=18080'
fi
docker exec "$container" grep -qx '      port: 18080' /etc/cassandra-reaper/config/cassandra-reaper.yml ||
  fail 'rendered config does not carry the overridden app port'

clusters=$(fetch "$container" http://127.0.0.1:18080/cluster) || fail 'GET /cluster failed'
[ "$clusters" = '[]' ] || fail "unexpected cluster list on fresh memory storage: $clusters"

# The bundled web UI must be served from the shaded jar.
fetch "$container" http://127.0.0.1:18080/webui/index.html | grep -qi '<html' ||
  fail 'web UI index.html not served'

# Memory storage persists to the declared volume.
docker exec "$container" sh -c 'ls -A /var/lib/cassandra-reaper/storage | grep -q .' ||
  fail 'memory storage directory is empty'

[ "$(docker exec "$container" id -u)" = 1001 ] || fail 'container process is not uid 1001'
out=$(docker exec "$container" spreaper ping --reaper-port 18080 2>&1) || fail "spreaper ping failed: $out"
printf '%s\n' "$out" | grep -q 'is answering in: localhost:18080' || fail "unexpected spreaper ping output: $out"

# --- Clean SIGTERM shutdown --------------------------------------------------
start=$(date +%s)
docker stop -t 30 "$container" >/dev/null
elapsed=$(($(date +%s) - start))
code=$(docker inspect -f '{{.State.ExitCode}}' "$container")
[ "$elapsed" -lt 30 ] || fail "SIGTERM shutdown took ${elapsed}s (killed at timeout)"
[ "$code" = 0 ] || [ "$code" = 143 ] || fail "unexpected exit code after SIGTERM: $code"
docker logs "$container" 2>&1 | grep -q 'Stopped' || fail 'no Jetty shutdown logged after SIGTERM'

# --- Negative: authentication enforced --------------------------------------
auth=$prefix-auth
docker run -d --name "$auth" --network none \
  -e REAPER_AUTH_ENABLED=true \
  -e REAPER_AUTH_USER=verity \
  -e REAPER_AUTH_PASSWORD=verity-test-password \
  -e JWT_SECRET=verity-smoke-test-secret-that-is-at-least-256-bits-long \
  -e REAPER_HEAP_SIZE=256m \
  "$image" >/dev/null || fail 'docker run (auth) failed'
wait_ready "$auth" 8081

status=$(http_status "$auth" http://127.0.0.1:8080/cluster)
[ "$status" = 401 ] || fail "unauthenticated GET /cluster returned '$status', want 401"
status=$(http_status "$auth" --data 'username=verity&password=wrong' http://127.0.0.1:8080/login)
[ "$status" = 401 ] || fail "login with a wrong password returned '$status', want 401"
login=$(fetch "$auth" --data 'username=verity&password=verity-test-password' \
  http://127.0.0.1:8080/login) || fail 'login with valid credentials failed'
token=$(printf '%s\n' "$login" | sed -n 's/.*"token" *: *"\([^"]*\)".*/\1/p')
[ -n "$token" ] || fail "login response carried no token: $login"
clusters=$(fetch "$auth" -H "Authorization: Bearer $token" http://127.0.0.1:8080/cluster) ||
  fail 'authenticated GET /cluster failed'
[ "$clusters" = '[]' ] || fail "unexpected authenticated cluster list: $clusters"

# spreaper login as used by the register-clusters command: credentials and JWT under ~/.reaper.
out=$(docker exec "$auth" sh -c 'mkdir -p ~/.reaper && printf %s verity-test-password > ~/.reaper/credentials &&
  spreaper login verity && spreaper list-clusters' 2>&1) || fail "spreaper login/list-clusters failed: $out"
printf '%s\n' "$out" | grep -q 'You are now authenticated to Reaper' || fail "spreaper login did not authenticate: $out"
docker rm -f "$auth" >/dev/null

# --- Negative: invalid storage type fails fast -------------------------------
bad=$prefix-bad
docker run -d --name "$bad" --network none -e REAPER_STORAGE_TYPE=bogus -e REAPER_AUTH_ENABLED=false \
  -e REAPER_HEAP_SIZE=256m "$image" >/dev/null || fail 'docker run (bad storage) failed'
code=$(timeout 120 docker wait "$bad") || fail 'invalid storage type did not stop the server'
[ "$code" != 0 ] || fail 'invalid storage type exited 0'
docker logs "$bad" 2>&1 | grep -qi 'invalid storage type' || fail 'invalid storage type error was not reported'

# --- Negative: upstream defaults enable auth, so no configured user fails closed --
noauth=$prefix-nouser
docker run -d --name "$noauth" --network none -e REAPER_HEAP_SIZE=256m \
  -e JWT_SECRET=verity-smoke-test-secret-that-is-at-least-256-bits-long "$image" >/dev/null ||
  fail 'docker run (default auth) failed'
code=$(timeout 120 docker wait "$noauth") || fail 'default auth without a user did not stop the server'
[ "$code" != 0 ] || fail 'default auth without a user exited 0'
docker logs "$noauth" 2>&1 | grep -q 'User configuration missing username' ||
  fail 'missing auth user error was not reported'

# --- Negative: auth on without a private JWT secret refuses to start ----------
jwt_refused() {
  name=$prefix-jwt-$1
  reason=$2
  shift 2
  docker run -d --name "$name" --network none -e REAPER_HEAP_SIZE=256m "$@" "$image" >/dev/null ||
    fail "docker run ($name) failed"
  code=$(timeout 30 docker wait "$name") || fail "$name: server did not refuse to start"
  [ "$code" = 64 ] || fail "$name: exited $code, want 64"
  docker logs "$name" 2>&1 | grep -q "$reason" || fail "$name: refusal reason '$reason' not reported"
  docker rm -f "$name" >/dev/null
}
jwt_refused unset 'JWT_SECRET is unset'
jwt_refused fallback 'public upstream fallback' \
  -e JWT_SECRET=MySecretKeyForJWTWhichMustBeLongEnoughForHS256Algorithm
jwt_refused explicit-auth 'JWT_SECRET is unset' -e REAPER_AUTH_ENABLED=True

printf 'SMOKE PASS\n'
