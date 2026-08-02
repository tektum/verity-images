#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE [FLAVOR]}
flavor=${2:-plain}
docker run --rm "$image" version | grep -q 'go1.26'

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
expected_version=off
if [ "$flavor" = fips ]; then
  expected_enabled=true
  expected_version=v1.0.0
fi
[ "$(docker run --rm "$image" env GOFIPS140)" = "$expected_version" ]
[ "$(docker run --rm -v "$work:/work:ro" -w /work "$image" run main.go)" = "$expected_enabled" ]
