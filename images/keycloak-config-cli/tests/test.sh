#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# Keycloak dev server, pinned by index digest at the keycloak.version the
# 6.5.1 pom builds against (26.5.5, upstream's 6.5.1-26.5.5 image). It runs
# only on an internal network shared with the CLI and the curl probe.
keycloak_index=quay.io/keycloak/keycloak:26.5.5@sha256:a7b0cb7a43a1235a61872883414d3f1d9a3ceac9df6e5907bd12202778a6265c
curl_index='docker.io/curlimages/curl:8.14.1@sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b'

id=$$
label="verity-test=keycloak-config-cli-$id"
network="verity-keycloak-config-cli-$id"
keycloak="verity-keycloak-config-cli-kc-$id"
work=$(mktemp -d)
# Bind-mount sources exist before the first run so Docker never creates them.
mkdir -p "$work/config" "$work/bad"
admin_user='admin'
admin_password="verity-$id"
realm=verity-smoke

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  docker logs "$keycloak" 2>&1 | tail -n 20 >&2 || true
  exit 1
}

cleanup() {
  docker rm -f "$keycloak" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

# Resolve each helper index to the child matching the image architecture and
# pull it explicitly. Running an index digest directly fails on multi-arch
# runners ("cannot overwrite digest") once another platform was pulled. The
# index bytes are verified against the pin before a child is chosen.
image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
pin_helper() {
  raw=$(docker buildx imagetools inspect --raw "$1") ||
    fail "cannot inspect helper index $1"
  [ "sha256:$(printf '%s' "$raw" | sha256sum | cut -d' ' -f1)" = "${1#*@}" ] ||
    fail "helper index digest mismatch for $1"
  child=$(printf '%s' "$raw" |
    jq -r --arg arch "$image_arch" '
      [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
      | if length == 1 then .[0] else empty end') ||
    fail "cannot resolve helper digest for $1"
  case $child in
    sha256:*) ;;
    *) fail "no unique linux/$image_arch helper image in $1" ;;
  esac
  repo=${1%@*}
  repo=${repo%:*}
  docker pull --quiet --platform "linux/$image_arch" "$repo@$child" >/dev/null ||
    fail "cannot pull helper $repo@$child"
  printf '%s@%s\n' "$repo" "$child"
}
keycloak_ref=$(pin_helper "$keycloak_index")
curl_ref=$(pin_helper "$curl_index")

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'

# OCI contract: upstream USER 65534, no WORKDIR, the shell-form JAVA_OPTS
# entrypoint, no CMD, and the upstream environment defaults.
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65534 ||
  fail 'unexpected OCI user'
# shellcheck disable=SC2016 # literal shell text of the entrypoint
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/bin/sh","-c","exec java $JAVA_OPTS -jar /app/keycloak-config-cli.jar \"$@\"","keycloak-config-cli"]' ||
  fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = / ||
  fail 'unexpected working directory'
envs=$(docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image")
for want in \
  'JAVA_OPTS=' \
  'KEYCLOAK_SSL_VERIFY=true' \
  'IMPORT_FILES_LOCATIONS=file:/config/*' \
  'JAVA_HOME=/opt/java/openjdk' \
  'PATH=/opt/java/openjdk/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'; do
  printf '%s\n' "$envs" | grep -Fx -- "$want" >/dev/null || fail "missing environment $want"
done

# Paths: the upstream jar location and the Temurin-style JAVA_HOME resolve,
# and java on PATH is a Java 21 runtime.
paths=$(docker run --rm --entrypoint /bin/sh "$image" -c \
  'test -f /app/keycloak-config-cli.jar && test -r /app/keycloak-config-cli.jar && echo jar
   command -v java
   java -version 2>&1 | head -n 1') || fail 'cannot probe image paths'
printf '%s\n' "$paths" | grep -Fx jar >/dev/null || fail '/app/keycloak-config-cli.jar is missing'
printf '%s\n' "$paths" | grep -Fx /opt/java/openjdk/bin/java >/dev/null ||
  fail 'java is not resolved from /opt/java/openjdk/bin'
printf '%s\n' "$paths" | grep -E '^openjdk version "21\.' >/dev/null || fail 'java is not OpenJDK 21'

# JAVA_OPTS is word-split into JVM options before -jar, as upstream does.
# JAVA_TOOL_OPTIONS is honored by the JVM as well. No Keycloak is reachable on
# a network-less container, so the import must fail with a nonzero status.
set +e
out=$(docker run --rm --network none \
  -e JAVA_OPTS='-XX:+PrintCommandLineFlags -Xmx123m' \
  -e JAVA_TOOL_OPTIONS='-Dverity.tool=1' \
  -e KEYCLOAK_URL=http://127.0.0.1:9 \
  "$image" 2>&1)
status=$?
set -e
[ "$status" -ne 0 ] || fail 'import without a reachable Keycloak exited 0'
printf '%s\n' "$out" | grep -F -- '-XX:MaxHeapSize=128974848' >/dev/null ||
  fail 'JAVA_OPTS -Xmx was not applied'
printf '%s\n' "$out" | grep -F -- '-XX:+PrintCommandLineFlags' >/dev/null ||
  fail 'JAVA_OPTS was not split into separate JVM options'
printf '%s\n' "$out" | grep -F 'Picked up JAVA_TOOL_OPTIONS: -Dverity.tool=1' >/dev/null ||
  fail 'JAVA_TOOL_OPTIONS was not honored'
printf '%s\n' "$out" | grep -E "Starting KeycloakConfigApplication v$expected_version " >/dev/null ||
  fail "application did not report version $expected_version"

docker network create --internal --label "$label" "$network" >/dev/null
docker run -d --name "$keycloak" --label "$label" --network "$network" \
  --network-alias keycloak \
  -e KC_BOOTSTRAP_ADMIN_USERNAME="$admin_user" \
  -e KC_BOOTSTRAP_ADMIN_PASSWORD="$admin_password" \
  "$keycloak_ref" start-dev >/dev/null || fail 'cannot start Keycloak'

# HTTP probes run a pinned curl on the internal network.
http() {
  docker run --rm --network "$network" "$curl_ref" -fsS --max-time 10 "$@"
}

i=0
until http http://keycloak:8080/realms/master 2>/dev/null | grep -F '"realm":"master"' >/dev/null; do
  [ "$(docker inspect --format '{{.State.Running}}' "$keycloak")" = true ] ||
    fail 'Keycloak exited before becoming ready'
  i=$((i + 1))
  [ "$i" -lt 120 ] || fail 'Keycloak did not become ready'
  sleep 2
done

cat > "$work/config/realm.json" <<EOF
{
  "realm": "$realm",
  "enabled": true,
  "displayName": "Verity smoke $id",
  "clients": [
    {
      "clientId": "verity-client",
      "enabled": true,
      "publicClient": true,
      "redirectUris": ["https://example.invalid/*"]
    }
  ],
  "roles": {
    "realm": [
      { "name": "verity-role" }
    ]
  }
}
EOF
printf '{ "realm": "broken", ' > "$work/bad/broken.json"
chmod 0644 "$work/config/realm.json" "$work/bad/broken.json"
chmod 0755 "$work/config" "$work/bad"

# Negative: a malformed file must fail the import with a nonzero status.
if docker run --rm --network "$network" --read-only --cap-drop=ALL \
  -v "$work/bad:/config:ro" \
  -e KEYCLOAK_URL=http://keycloak:8080 \
  -e KEYCLOAK_USER="$admin_user" -e KEYCLOAK_PASSWORD="$admin_password" \
  "$image" >"$work/bad.log" 2>&1; then
  cat "$work/bad.log" >&2
  fail 'malformed realm file imported successfully'
fi

# Import from the default IMPORT_FILES_LOCATIONS (file:/config/*) as the
# upstream nobody user on a read-only root. The argument checks that container
# arguments reach Spring Boot intact through the shell wrapper.
docker run --rm --network "$network" --read-only --cap-drop=ALL \
  -v "$work/config:/config:ro" \
  -e KEYCLOAK_URL=http://keycloak:8080 \
  -e KEYCLOAK_USER="$admin_user" -e KEYCLOAK_PASSWORD="$admin_password" \
  "$image" '--import.var-substitution.enabled=false' >"$work/import.log" 2>&1 || {
  cat "$work/import.log" >&2
  fail 'realm import failed'
}
grep -F "Importing file 'file:/config/realm.json'" "$work/import.log" >/dev/null || {
  cat "$work/import.log" >&2
  fail 'import did not read /config/realm.json from IMPORT_FILES_LOCATIONS'
}

# Verify through the Keycloak admin REST API.
token=$(http -d grant_type=password -d client_id=admin-cli \
  --data-urlencode "username=$admin_user" --data-urlencode "password=$admin_password" \
  http://keycloak:8080/realms/master/protocol/openid-connect/token |
  sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p') || fail 'cannot request an admin token'
[ -n "$token" ] || fail 'admin token response had no access_token'

realm_json=$(http -H "Authorization: Bearer $token" \
  "http://keycloak:8080/admin/realms/$realm") || fail "admin API has no realm $realm"
printf '%s\n' "$realm_json" | grep -F "\"realm\":\"$realm\"" >/dev/null ||
  fail "admin API returned the wrong realm: $realm_json"
printf '%s\n' "$realm_json" | grep -F "\"displayName\":\"Verity smoke $id\"" >/dev/null ||
  fail 'imported realm displayName does not match'
printf '%s\n' "$realm_json" | grep -F '"enabled":true' >/dev/null ||
  fail 'imported realm is not enabled'

clients=$(http -H "Authorization: Bearer $token" \
  "http://keycloak:8080/admin/realms/$realm/clients?clientId=verity-client") ||
  fail 'cannot list imported clients'
printf '%s\n' "$clients" | grep -F '"clientId":"verity-client"' >/dev/null ||
  fail 'imported client verity-client is missing'
http -H "Authorization: Bearer $token" \
  "http://keycloak:8080/admin/realms/$realm/roles/verity-role" | grep -F '"name":"verity-role"' >/dev/null ||
  fail 'imported realm role verity-role is missing'

# The malformed import must not have created its realm.
if http -H "Authorization: Bearer $token" \
  http://keycloak:8080/admin/realms/broken >/dev/null 2>&1; then
  fail 'malformed import created realm broken'
fi

printf 'keycloak-config-cli smoke test passed\n'
