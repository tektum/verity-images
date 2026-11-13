#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf '%s\n' 'package version not found' >&2; exit 1; }
project="verity-compose-test-$$"
tmp=$(mktemp -d)
socket=/var/run/docker.sock

cleanup() {
  docker ps -aq --filter "label=com.docker.compose.project=$project" |
    xargs -r docker rm -f >/dev/null 2>&1 || true
  docker network ls -q --filter "label=com.docker.compose.project=$project" |
    xargs -r docker network rm >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532 ] ||
  fail 'unexpected image config: User'
[ "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/docker-compose"]' ] ||
  fail 'unexpected image config: Entrypoint'

actual=$(docker run --rm "$image" version) || fail 'docker-compose version failed'
[ "$actual" = "Docker Compose version v$expected_version" ] ||
  fail "unexpected version output: $actual"

chmod 755 "$tmp"
cat >"$tmp/compose.yaml" <<'EOF'
services:
  web:
    image: example.invalid/web:${WEB_TAG:-1.0}
    ports:
      - "8080:80"
    environment:
      GREETING: ${GREETING}
  worker:
    image: example.invalid/worker:2
    depends_on: [web]
EOF
chmod 644 "$tmp/compose.yaml"

# Interpolation, defaults, and normalization need no daemon.
docker run --rm --read-only -v "$tmp:/work:ro" -w /work -e GREETING=hello "$image" \
  config --format json >"$tmp/config.json" || fail 'docker-compose config failed'
[ "$(jq -r '.services.web.image' "$tmp/config.json")" = example.invalid/web:1.0 ] ||
  fail 'default interpolation was not applied'
[ "$(jq -r '.services.web.environment.GREETING' "$tmp/config.json")" = hello ] ||
  fail 'environment interpolation was not applied'
[ "$(jq -r '.services.web.ports[0].published' "$tmp/config.json")" = 8080 ] ||
  fail 'port mapping was not normalized'
[ "$(docker run --rm --read-only -v "$tmp:/work:ro" -w /work -e GREETING=hello "$image" config --services | sort | tr '\n' ' ')" = 'web worker ' ] ||
  fail 'unexpected service list'

# A real project lifecycle against the host daemon, using this image as the
# service image so no registry access is needed.
if [ -S "$socket" ]; then
  socket_gid=$(stat -c %g "$socket")
  cat >"$tmp/lifecycle.yaml" <<EOF
services:
  probe:
    image: $image
    pull_policy: never
    command: ["version", "--short"]
EOF
  chmod 644 "$tmp/lifecycle.yaml"
  docker run --rm --read-only --tmpfs /tmp -e HOME=/tmp --group-add "$socket_gid" \
    -v "$socket:/var/run/docker.sock" -v "$tmp:/work:ro" -w /work "$image" \
    -p "$project" -f lifecycle.yaml up --abort-on-container-exit --exit-code-from probe \
    >"$tmp/up.log" 2>&1 || { cat "$tmp/up.log" >&2; fail 'docker-compose up failed'; }
  grep -F "$expected_version" "$tmp/up.log" >/dev/null || {
    cat "$tmp/up.log" >&2
    fail 'service output not attached'
  }
  docker run --rm --read-only --tmpfs /tmp -e HOME=/tmp --group-add "$socket_gid" \
    -v "$socket:/var/run/docker.sock" -v "$tmp:/work:ro" -w /work "$image" \
    -p "$project" -f lifecycle.yaml down >/dev/null 2>&1 || fail 'docker-compose down failed'
  [ -z "$(docker ps -aq --filter "label=com.docker.compose.project=$project")" ] ||
    fail 'docker-compose down left containers behind'
else
  printf 'skipping daemon lifecycle check: %s is not a socket\n' "$socket" >&2
fi

# Negative cases: a schema violation and a missing compose file.
cat >"$tmp/invalid.yaml" <<'EOF'
services:
  web:
    image: example.invalid/web:1
    ports: "not-a-list"
EOF
chmod 644 "$tmp/invalid.yaml"
if docker run --rm -v "$tmp:/work:ro" -w /work "$image" -f invalid.yaml config \
  >"$tmp/invalid.log" 2>&1; then
  fail 'invalid compose file unexpectedly succeeded'
fi
grep -F 'ports' "$tmp/invalid.log" >/dev/null || {
  cat "$tmp/invalid.log" >&2
  fail 'invalid compose file error is not readable'
}
if docker run --rm "$image" -f /nonexistent.yaml config >"$tmp/missing.log" 2>&1; then
  fail 'missing compose file unexpectedly succeeded'
fi
grep -F 'nonexistent.yaml' "$tmp/missing.log" >/dev/null || {
  cat "$tmp/missing.log" >&2
  fail 'missing compose file error is not readable'
}

printf 'SMOKE PASS image=%s\n' "$image"
