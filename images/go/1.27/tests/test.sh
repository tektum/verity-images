#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE [FLAVOR]}
flavor=${2:-plain}
expected_go_version=$(sed -n 's/^  version: "\([^"]*\)"$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_go_version" ] || { printf 'package version not found\n' >&2; exit 1; }
[ "$(docker run --rm "$image" version | awk '{print $3}')" = "go$expected_go_version" ]
[ "$(docker run --rm "$image" env GOROOT)" = /usr/lib/go ]

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
cat > "$work/main.go" <<'EOF'
package main

import (
	"crypto/fips140"
	"fmt"
)

func main() {
	fmt.Printf("%t\n", fips140.Enabled())
}
EOF

expected_enabled=false
expected_fips=off
if [ "$flavor" = fips ]; then
  expected_enabled=true
  expected_fips=v1.0.0
fi
[ "$(docker run --rm "$image" env GOFIPS140)" = "$expected_fips" ]
[ "$(docker run --rm -v "$work:/work:ro" -w /work "$image" run main.go)" = "$expected_enabled" ]
