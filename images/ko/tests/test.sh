#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^versions: \[\([^]]*\)\]$/\1/p' "$(dirname "$0")/../metadata.yaml")
[ -n "$expected_version" ] || { echo 'metadata version not found' >&2; exit 1; }
work=$(mktemp -d)
built=

cleanup() {
  [ -z "$built" ] || docker image rm -f "$built" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect -f '{{.Config.Entrypoint}}' "$image")" = '[/usr/bin/ko]' ] || fail 'unexpected OCI entrypoint'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /app ] || fail 'unexpected OCI working directory'
version=$(docker run --rm --network none "$image" version)
[ "$version" = "$expected_version" ] || fail 'unexpected ko version'

cat > "$work/go.mod" <<'EOF'
module example.com/ko-smoke

go 1.26
EOF
cat > "$work/main.go" <<'EOF'
package main

import "fmt"

func main() {
	fmt.Println("ko-smoke")
}
EOF

docker run --rm \
  -v "$work:/app" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  "$image" build --local --image-refs=/app/image-refs . >/dev/null
built=$(cat "$work/image-refs")
[ "$(docker run --rm "$built")" = ko-smoke ] || fail 'ko local build did not produce a runnable image'

if docker run --rm \
  -v "$work:/app" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  "$image" build --local ./missing >/dev/null 2>&1; then
  fail 'invalid import unexpectedly succeeded'
fi

printf 'SMOKE PASS image=%s\n' "$image"
