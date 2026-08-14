#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-fluent-bit-test-$$"
work=$(mktemp -d)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM
chmod 755 "$work"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected OCI user'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/fluent-bit"]' ] || fail 'unexpected OCI entrypoint'
[ "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["-c","/etc/fluent-bit/fluent-bit.conf"]' ] || fail 'unexpected OCI command'

cat > "$work/parsers.conf" <<'EOF'
[PARSER]
    Name json
    Format json
EOF
cat > "$work/fluent-bit.conf" <<'EOF'
[SERVICE]
    Flush 1
    Parsers_File /tmp/parsers.conf

[INPUT]
    Name dummy
    Tag smoke
    Dummy {"message":"fluent-bit smoke"}
    Samples 1

[OUTPUT]
    Name stdout
    Match smoke
EOF
chmod 644 "$work/fluent-bit.conf" "$work/parsers.conf"

docker run --rm --network none --read-only \
  -v "$work/fluent-bit.conf:/tmp/fluent-bit.conf:ro" \
  -v "$work/parsers.conf:/tmp/parsers.conf:ro" \
  "$image" --dry-run -c /tmp/fluent-bit.conf >/dev/null || fail 'valid configuration was rejected'

docker run --name "$container" -d --network none --read-only \
  -v "$work/fluent-bit.conf:/tmp/fluent-bit.conf:ro" \
  -v "$work/parsers.conf:/tmp/parsers.conf:ro" \
  "$image" -c /tmp/fluent-bit.conf >/dev/null
i=0
until docker logs "$container" 2>&1 | grep -q 'fluent-bit smoke'; do
  i=$((i + 1))
  [ "$i" -lt 20 ] || { docker logs "$container" >&2 || true; fail 'dummy record was not emitted'; }
  sleep 1
done
docker stop "$container" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ] || fail 'Fluent Bit did not stop cleanly'
docker rm "$container" >/dev/null
container=

cat > "$work/invalid.conf" <<'EOF'
[INPUT
    Name dummy
EOF
if output=$(docker run --rm --network none --read-only \
  -v "$work/invalid.conf:/tmp/invalid.conf:ro" \
  "$image" --dry-run -c /tmp/invalid.conf 2>&1); then
  printf '%s\n' "$output" >&2
  fail 'invalid configuration unexpectedly succeeded'
fi
printf '%s' "$output" | grep -Eqi 'error|invalid' || {
  printf '%s\n' "$output" >&2
  fail 'invalid configuration diagnostic missing'
}

cat > "$work/invalid-parsers.conf" <<'EOF'
[PARSER
    Name broken
    Format json
EOF
cat > "$work/parser-check.conf" <<'EOF'
[SERVICE]
    Parsers_File /tmp/invalid-parsers.conf

[INPUT]
    Name dummy
    Parser broken

[OUTPUT]
    Name stdout
    Match *
EOF
container="verity-fluent-bit-parser-test-$$"
docker run --name "$container" -d --network none --read-only \
  -v "$work/parser-check.conf:/tmp/parser-check.conf:ro" \
  -v "$work/invalid-parsers.conf:/tmp/invalid-parsers.conf:ro" \
  "$image" -c /tmp/parser-check.conf >/dev/null
i=0
while [ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ]; do
  i=$((i + 1))
  [ "$i" -lt 10 ] || { docker logs "$container" >&2 || true; fail 'invalid parser configuration kept running'; }
  sleep 1
done
output=$(docker logs "$container" 2>&1)
[ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" != 0 ] || fail 'invalid parser configuration exited successfully'
printf '%s' "$output" | grep -Eqi 'error|invalid' || {
  printf '%s\n' "$output" >&2
  fail 'invalid parser diagnostic missing'
}
docker rm "$container" >/dev/null
container=

printf 'SMOKE PASS image=%s\n' "$image"
