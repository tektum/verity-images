#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
tmp=$(mktemp -d)

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM
chmod 755 "$tmp"

test "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532 || {
  printf '%s\n' 'image user is not 65532' >&2
  exit 1
}
test "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/vector"]' || {
  printf '%s\n' 'unexpected image entrypoint' >&2
  exit 1
}
docker run --rm --entrypoint /usr/bin/vector "$image" --version | grep -F 'vector 0.51.1' >/dev/null || {
  printf '%s\n' 'unexpected Vector version' >&2
  exit 1
}

cat >"$tmp/vector.toml" <<'EOF'
data_dir = "/var/lib/vector"

[sources.stdin]
type = "stdin"

[sinks.console]
type = "console"
inputs = ["stdin"]
encoding.codec = "json"
EOF
chmod 644 "$tmp/vector.toml"

output=$(printf '%s\n' 'hello-vector' | docker run --rm -i \
  -v "$tmp/vector.toml:/etc/vector/vector.toml:ro" \
  "$image" --config-toml /etc/vector/vector.toml 2>/dev/null)
printf '%s\n' "$output" | grep -F '"message":"hello-vector"' >/dev/null || {
  printf 'unexpected Vector output: %s\n' "$output" >&2
  exit 1
}

printf '%s\n' '[sources.stdin' >"$tmp/invalid.toml"
chmod 644 "$tmp/invalid.toml"
if docker run --rm -v "$tmp/invalid.toml:/etc/vector/invalid.toml:ro" \
  "$image" validate --no-environment --config-toml /etc/vector/invalid.toml \
  >/dev/null 2>&1; then
  printf '%s\n' 'invalid TOML unexpectedly succeeded' >&2
  exit 1
fi

printf 'SMOKE PASS image=%s\n' "$image"
