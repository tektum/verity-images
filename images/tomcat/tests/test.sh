#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-tomcat-test-$$"
work=$(mktemp -d)

fail() {
  printf '%s\n' "$1" >&2
  docker logs "$container" >&2 2>&1 || true
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /usr/share/tomcat ] || fail 'unexpected OCI working directory'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' "$image")" = 'null ["catalina.sh","run"]' ] || fail 'unexpected OCI command'

version=$(docker run --rm --network none "$image" version.sh) || fail 'version.sh failed'
printf '%s\n' "$version" | grep -Eq '^Server version: Apache Tomcat/11\.0\.[0-9]+$' || fail 'unexpected Tomcat version'
printf '%s\n' "$version" | grep -Eq '^JVM Version: +21\.' || fail 'unexpected JVM version'
printf '%s\n' "$version" | grep -Eq '^APR loaded: +true$' || fail 'Tomcat Native library did not load'

mkdir -p "$work/hello"
cat > "$work/hello/index.jsp" <<'EOF'
<%@ page contentType="text/plain" %>verity-tomcat <%= 6 * 7 %> <%= System.getProperty("user.name") %>
EOF
chmod -R a+rX "$work"

docker run --name "$container" -d -p 127.0.0.1::8080 \
  -v "$work/hello:/usr/share/tomcat/webapps/hello:ro" "$image" >/dev/null
port=$(docker port "$container" 8080/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || fail 'no published port'

i=0
until response=$(curl --fail --silent --connect-timeout 1 --max-time 10 "http://127.0.0.1:$port/hello/"); do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'exploded JSP webapp never became ready'
  sleep 1
done
printf '%s\n' "$response" | grep -Eq '^verity-tomcat 42 ' || fail "unexpected JSP response: $response"

status=$(curl --silent --output "$work/missing.html" --write-out '%{http_code}' --max-time 10 "http://127.0.0.1:$port/does-not-exist/")
[ "$status" = 404 ] || fail "unexpected status for missing context: $status"
grep -q 'Apache Tomcat/11\.0\.' "$work/missing.html" || fail '404 page did not come from Tomcat'

docker exec "$container" cp /usr/share/tomcat/webapps.dist/docs/appdev/sample/sample.war /usr/share/tomcat/webapps/ ||
  fail 'non-root user cannot write webapps'
i=0
until response=$(curl --fail --silent --connect-timeout 1 --max-time 10 "http://127.0.0.1:$port/sample/"); do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'WAR was not hot deployed'
  sleep 1
done
printf '%s\n' "$response" | grep -Fq 'Sample "Hello, World" Application' || fail 'unexpected WAR response'

if docker logs "$container" 2>&1 | grep -q 'SEVERE'; then
  fail 'Tomcat logged a SEVERE error'
fi

docker stop "$container" >/dev/null
# The JVM exits with 128 + SIGTERM after running Tomcat's shutdown hook.
[ "$(docker inspect -f '{{.State.ExitCode}}' "$container")" = 143 ] || fail 'unexpected exit status after SIGTERM'
docker logs "$container" 2>&1 | grep -Fq 'Stopping service [Catalina]' || fail 'Tomcat did not shut down gracefully'

printf '<Server' > "$work/server.xml"
chmod a+r "$work/server.xml"
if output=$(docker run --rm --network none -v "$work/server.xml:/usr/share/tomcat/conf/server.xml:ro" "$image" 2>&1); then
  fail 'malformed server.xml unexpectedly started'
fi
printf '%s\n' "$output" | grep -Fq 'Cannot start server, server instance is not configured' ||
  fail 'malformed server.xml did not report a configuration error'
printf '%s\n' "$output" | grep -Fq 'conf/server.xml' || fail 'configuration error did not identify server.xml'

printf 'SMOKE PASS\n'
