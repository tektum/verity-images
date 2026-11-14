#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# Every run uses --network none. A real `xcaddy build` downloads Caddy and its
# plugins through the Go module proxy, so it cannot complete offline; the test
# covers what can be checked without the network: the xcaddy CLI, the bundled
# Go toolchain compiling a program, and xcaddy driving that toolchain up to the
# first module download, which must fail cleanly.
work=$(mktemp -d)

cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

config=$here/../apko.yaml
expected_version=$(sed -n 's/^    - xcaddy=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
go_stream=$(sed -n 's/^    - go-\([0-9]*\.[0-9]*\)$/\1/p' "$config")
[ -n "$expected_version" ] || fail 'could not read the pinned xcaddy version'
[ -n "$go_stream" ] || fail 'could not read the Go toolchain stream'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/xcaddy"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" \
  >"$work/env"
for entry in GOTOOLCHAIN=local GOPATH=/home/nonroot/go \
  GOCACHE=/home/nonroot/.cache/go-build \
  SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt; do
  grep -Fx "$entry" "$work/env" >/dev/null || fail "missing environment entry $entry"
done

run() {
  docker run --rm --network none --read-only --cap-drop ALL \
    --tmpfs /tmp:rw,exec,mode=1777 \
    --tmpfs /home/nonroot:rw,uid=65532,gid=65532,mode=0755 "$@"
}

run "$image" version >"$work/version" || fail 'xcaddy version failed'
grep -Fx "v$expected_version" "$work/version" >/dev/null ||
  fail "xcaddy version does not report v$expected_version: $(cat "$work/version")"

if run "$image" --definitely-invalid >"$work/invalid" 2>&1; then
  fail 'invalid flag unexpectedly succeeded'
fi
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'invalid flag diagnostic is missing'

# The bundled toolchain is the configured Go stream and builds a program offline.
run --entrypoint /usr/bin/go "$image" version >"$work/go-version" ||
  fail 'go version failed'
arch=$(docker image inspect -f '{{.Architecture}}' "$image")
grep -Ex "go version go$(printf '%s' "$go_stream" | sed 's/\./\\./g')\.[0-9]+ linux/$arch" \
  "$work/go-version" >/dev/null || fail "unexpected Go toolchain: $(cat "$work/go-version")"

mkdir -p "$work/hello"
cat >"$work/hello/go.mod" <<'EOF'
module example.com/hello

go 1.24
EOF
cat >"$work/hello/main.go" <<'EOF'
package main

import (
	"crypto/sha256"
	"fmt"
)

func main() {
	fmt.Printf("hello verity %x\n", sha256.Sum256([]byte("xcaddy")))
}
EOF
chmod 0755 "$work/hello"
chmod 0644 "$work/hello/go.mod" "$work/hello/main.go"
expected_sum=$(printf 'xcaddy' | sha256sum | cut -d' ' -f1)
run -v "$work/hello:/src:ro" -w /src --entrypoint /usr/bin/go "$image" \
  run . >"$work/hello.out" 2>&1 || fail "go run failed: $(cat "$work/hello.out")"
grep -Fx "hello verity $expected_sum" "$work/hello.out" >/dev/null ||
  fail "unexpected program output: $(cat "$work/hello.out")"

# Negative: plugin pass-through outside a Go module fails cleanly.
if run "$image" list-modules >"$work/list-modules" 2>&1; then
  fail 'list-modules outside a module unexpectedly succeeded'
fi
grep -F 'go.mod file not found' "$work/list-modules" >/dev/null ||
  fail "list-modules diagnostic is missing: $(cat "$work/list-modules")"

# Negative: offline, `xcaddy build` sets up its build module with the bundled
# Go, pins the requested Caddy version, then fails on the module download
# without producing a binary.
if run "$image" build v2.10.2 --output /tmp/caddy >"$work/build" 2>&1; then
  fail 'offline xcaddy build unexpectedly succeeded'
fi
for line in 'exec (timeout=0s): /usr/bin/go mod init caddy' \
  'exec (timeout=0s): /usr/bin/go get -v github.com/caddyserver/caddy/v2@v2.10.2' \
  'proxy.golang.org'; do
  grep -F "$line" "$work/build" >/dev/null ||
    fail "offline build output lacks '$line': $(cat "$work/build")"
done

printf 'SMOKE PASS image=%s version=%s %s\n' "$image" "$expected_version" "$(cat "$work/go-version")"
