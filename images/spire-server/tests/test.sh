#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
prefix="verity-spire-server-test-$$"
server="$prefix-server"
restarted="$prefix-restarted"
volume="$prefix-data"
cli=/opt/spire/bin/spire-server
work=$(mktemp -d)

cleanup() {
  docker rm -f "$server" "$restarted" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || fail 'package version not found in melange.yaml'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 1000 ||
  fail 'OCI user is not 1000'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  "[\"$cli\",\"run\"]" || fail 'unexpected entrypoint'
case $(docker image inspect --format '{{json .Config.Cmd}}' "$image") in
  null | '[]') ;;
  *) fail 'unexpected default command' ;;
esac
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /opt/spire ||
  fail 'unexpected working directory'

version=$(docker run --rm --network none --entrypoint "$cli" "$image" --version 2>&1) ||
  fail 'spire-server --version failed'
[ "$version" = "$expected_version" ] ||
  fail "spire-server reports version $version, expected $expected_version"

if docker run --rm --network none --read-only "$image" --definitely-invalid \
  >"$work/invalid" 2>&1; then
  fail 'unknown flag unexpectedly succeeded'
fi
grep -F 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'unknown flag diagnostic is missing'

if docker run --rm --network none --read-only "$image" >"$work/no-config" 2>&1; then
  fail 'server started without a configuration file'
fi
grep -F 'could not find config file /opt/spire/conf/server/server.conf' "$work/no-config" \
  >/dev/null || fail 'missing configuration diagnostic is missing'

cat >"$work/server.conf" <<'EOF'
server {
  bind_address = "127.0.0.1"
  bind_port = "8081"
  trust_domain = "example.org"
  data_dir = "/var/lib/spire/server"
  log_level = "INFO"
}

plugins {
  DataStore "sql" {
    plugin_data {
      database_type = "sqlite3"
      connection_string = "/var/lib/spire/server/datastore.sqlite3"
    }
  }
  KeyManager "memory" {
    plugin_data {}
  }
  NodeAttestor "join_token" {
    plugin_data {}
  }
}
EOF
sed 's/"example.org"/"Not A Domain"/' "$work/server.conf" >"$work/invalid.conf"
chmod 644 "$work/server.conf" "$work/invalid.conf"

docker run --rm --network none -v "$work/server.conf:/etc/spire/server/server.conf:ro" \
  --entrypoint "$cli" "$image" validate -config /etc/spire/server/server.conf \
  >"$work/validate" 2>&1 || fail 'valid configuration was rejected'
grep -Fx 'SPIRE server configuration file is valid.' "$work/validate" >/dev/null ||
  fail 'configuration validation output is missing'
if docker run --rm --network none -v "$work/invalid.conf:/etc/spire/server/server.conf:ro" \
  --entrypoint "$cli" "$image" validate -config /etc/spire/server/server.conf \
  >"$work/validate-invalid" 2>&1; then
  fail 'invalid trust domain passed validation'
fi
grep -F 'could not parse trust_domain "Not A Domain"' "$work/validate-invalid" >/dev/null ||
  fail 'invalid trust domain diagnostic is missing'

start_server() {
  docker run -d --name "$1" --network none --read-only --tmpfs /tmp:rw,mode=1777 \
    -v "$volume:/var/lib/spire/server" \
    -v "$work/server.conf:/etc/spire/server/server.conf:ro" \
    "$image" -config /etc/spire/server/server.conf >/dev/null ||
    fail "could not start $1"
  i=0
  until docker exec "$1" "$cli" healthcheck >"$work/health" 2>&1; do
    i=$((i + 1))
    if [ "$i" -ge 90 ]; then
      docker logs "$1" >&2 || true
      fail "spire-server in $1 did not become healthy"
    fi
    sleep 1
  done
  grep -Fx 'Server is healthy.' "$work/health" >/dev/null ||
    fail 'healthcheck output is unexpected'
}

docker volume create "$volume" >/dev/null || fail 'could not create the data volume'
start_server "$server"

docker exec "$server" "$cli" bundle show -output json >"$work/bundle.json" ||
  fail 'bundle show failed'
grep -F '"trust_domain":"example.org"' "$work/bundle.json" >/dev/null ||
  fail 'bundle trust domain is not example.org'
grep -F '"x509_authorities":[{"asn1":"' "$work/bundle.json" >/dev/null ||
  fail 'bundle has no X.509 authority'
docker exec "$server" "$cli" bundle show >"$work/bundle.pem" || fail 'PEM bundle show failed'
grep -Fx -- '-----BEGIN CERTIFICATE-----' "$work/bundle.pem" >/dev/null ||
  fail 'bundle is not a PEM certificate'

docker exec "$server" "$cli" entry create -parentID spiffe://example.org/node \
  -spiffeID spiffe://example.org/workload -selector unix:uid:1000 >"$work/entry" 2>&1 ||
  fail 'registration entry was rejected'
grep -E '^SPIFFE ID +: spiffe://example.org/workload$' "$work/entry" >/dev/null ||
  fail 'registration entry output is missing the SPIFFE ID'
if docker exec "$server" "$cli" entry create -parentID spiffe://example.org/node \
  -spiffeID spiffe://other.test/workload -selector unix:uid:1000 >"$work/foreign" 2>&1; then
  fail 'entry outside the trust domain was accepted'
fi
grep -F 'is not a member of trust domain' "$work/foreign" >/dev/null ||
  fail 'foreign trust domain diagnostic is missing'
docker exec "$server" "$cli" token generate -spiffeID spiffe://example.org/node \
  >"$work/token" 2>&1 || fail 'join token generation failed'
grep -E '^Token: [0-9a-f-]{36}$' "$work/token" >/dev/null || fail 'join token output is unexpected'

docker stop "$server" >/dev/null || fail 'could not stop the server'
test "$(docker inspect --format '{{.State.ExitCode}}' "$server")" = 0 ||
  fail 'server did not exit cleanly on SIGTERM'

start_server "$restarted"
docker exec "$restarted" "$cli" entry show -spiffeID spiffe://example.org/workload \
  >"$work/persisted" 2>&1 || fail 'entry show failed after restart'
grep -Fx 'Found 1 entry' "$work/persisted" >/dev/null ||
  fail 'registration entry did not persist in the SQLite datastore'

printf 'SMOKE PASS image=%s\n' "$image"
