#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
config="$(dirname "$0")/../apko.yaml"
version=$(sed -n 's/^    - spin=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
label="verity-test=spin-$$"
container="verity-spin-test-$$"
work=$(mktemp -d)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  docker logs "$container" >&2 2>/dev/null || true
  exit 1
}

[ -n "$version" ] || fail 'could not read the pinned spin version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/spin"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

run() {
  docker run --rm --label "$label" --network none --read-only \
    --tmpfs /tmp:rw,mode=1777 -v "$work/app:/work:ro" "$image" "$@"
}

# Fixture: a Spin app whose one HTTP route runs a hand-assembled WASI module
# through the WAGI (CGI) executor; the module writes a header block and a body.
mkdir -p "$work/app" "$work/bad"
printf '%s' 'AGFzbQEAAAABEgNgBH9/f38Bf2AAAGACf38BfwIjARZ3YXNpX3NuYXBzaG90X3ByZXZpZXcxCGZkX3dyaXRlAAADAwIBAgUDAQABBxkDBm1lbW9yeQIABl9zdGFydAABA2FkZAACCiYCHABBAEEINgIAQQRBKjYCAEEBQQBBAUGACBAAGgsHACAAIAFqCwswAQBBCAsqY29udGVudC10eXBlOiB0ZXh0L3BsYWluCgpoZWxsbyBmcm9tIHNwaW4K' |
  base64 -d >"$work/app/cgi.wasm"
cat >"$work/app/spin.toml" <<'TOML'
spin_manifest_version = 2

[application]
name = "smoke"
version = "0.1.0"

[[trigger.http]]
route = "/hello"
component = "hello"
executor = { type = "wagi" }

[component.hello]
source = "cgi.wasm"
TOML
printf 'spin_manifest_version = 2\n[application\n' >"$work/bad/spin.toml"
chmod -R a+rwX "$work"

# stdout only: docker prints a platform mismatch warning on stderr for emulated arm64 runs.
out=$(run --version) || fail 'version failed'
case "$out" in
  "spin $version "*) ;;
  *) fail "version does not report $version: $out" ;;
esac

# Negative: an unknown flag and an invalid manifest are rejected.
if run --definitely-not-a-flag >"$work/flag.log" 2>&1; then
  fail 'unknown flag was accepted'
fi
grep -q "unexpected argument '--definitely-not-a-flag'" "$work/flag.log" ||
  fail "unexpected unknown-flag error: $(cat "$work/flag.log")"
if docker run --rm --label "$label" --network none --read-only --tmpfs /tmp:rw,mode=1777 \
  -v "$work/bad:/work" "$image" up >"$work/bad.log" 2>&1; then
  fail 'an invalid manifest was accepted'
fi
grep -q 'TOML parse error' "$work/bad.log" || fail "invalid manifest error is not a TOML parse error: $(cat "$work/bad.log")"

# Serve the app from a read-only mount on a read-only root filesystem, with
# runtime state on /tmp, and call the route. Wasmtime
# keeps its compilation cache under $HOME/.cache, so HOME gets a tmpfs.
docker run -d --name "$container" --label "$label" --read-only --tmpfs /tmp:rw,mode=1777 \
  --tmpfs /home/nonroot:rw,uid=65532,gid=65532,mode=0755 \
  -v "$work/app:/work:ro" -p 127.0.0.1::3000 "$image" \
  up --listen 0.0.0.0:3000 --state-dir /tmp/spin >/dev/null
port=$(docker port "$container" 3000/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || fail 'spin port not published'

i=0
until curl -fsS --max-time 5 -D "$work/h1" -o "$work/b1" "http://127.0.0.1:$port/hello" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'spin never served the route'
  sleep 1
done
test "$(cat "$work/b1")" = 'hello from spin' || fail "unexpected body: $(cat "$work/b1")"
tr -d '\r' <"$work/h1" | grep -qix 'content-type: text/plain' ||
  fail "component header not passed through: $(cat "$work/h1")"

# Negative: an unrouted path is a 404 from the Spin router.
code=$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/missing" || true)
[ "$code" = 404 ] || fail "unrouted path returned $code, want 404"

uid=$(docker top "$container" -o pid,uid,comm | awk '$3 == "spin" { print $2; exit }')
[ "$uid" = 65532 ] || fail "spin runs as uid $uid, want 65532"

docker logs "$container" 2>&1 | grep -q 'hello: http://0.0.0.0:3000/hello' ||
  fail 'route listing missing from container output'

printf 'SMOKE PASS\n'
