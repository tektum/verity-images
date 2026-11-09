#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
recipe="$(dirname "$0")/../melange.yaml"
version=$(sed -n 's/^  version: "\([^"]*\)".*$/\1/p' "$recipe")

trap 'chmod -R u+w "$work" 2>/dev/null || true; rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/golangci-lint"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["run"]' ||
  fail 'unexpected default command'

# Offline, read-only root; only /tmp (cache, GOPATH) and the mounted module are writable.
run() {
  docker run --rm --network none --read-only --user "$(id -u):$(id -g)" \
    -e HOME=/tmp -e GOPATH=/tmp/go -e GOCACHE=/tmp/go-build -e GOFLAGS=-mod=mod \
    --tmpfs /tmp:rw,mode=1777 -v "$work:/work" -w /work "$@"
}

run "$image" version >"$work/version" 2>&1 || fail 'version failed'
grep -F "has version ${version}" "$work/version" >/dev/null || fail 'version is not embedded'

run "$image" --help >"$work/help" 2>&1 || fail 'help failed'
grep -F 'Usage:' "$work/help" >/dev/null || fail 'help is missing usage text'

# The runtime Go toolchain is part of the contract: linting shells out to go list.
run --entrypoint /usr/bin/go "$image" version >"$work/go-version" 2>&1 || fail 'go version failed'
grep -E '^go version go1\.26\.' "$work/go-version" >/dev/null || fail 'unexpected Go toolchain'

mkdir "$work/leaky" "$work/clean"

cat >"$work/leaky/go.mod" <<'EOF'
module example.invalid/leaky

go 1.26
EOF
cat >"$work/leaky/main.go" <<'EOF'
package main

import "fmt"

// seededUnused is never referenced, so the unused linter must report it.
var seededUnused = 42

func main() {
	fmt.Println("hello")
}
EOF

cat >"$work/clean/go.mod" <<'EOF'
module example.invalid/clean

go 1.26
EOF
cat >"$work/clean/main.go" <<'EOF'
package main

import "fmt"

func main() {
	fmt.Println("hello")
}
EOF
chmod -R a+rX "$work"

# Seeded unused variable: exit 1 and the finding names the identifier and linter.
rc=0
run -w /work/leaky "$image" run ./... >"$work/leaky.out" 2>&1 || rc=$?
test "$rc" = 1 || fail "leaky module exit code $rc, expected 1"
grep -F 'seededUnused' "$work/leaky.out" >/dev/null || fail 'unused finding does not name the identifier'
grep -F '(unused)' "$work/leaky.out" >/dev/null || fail 'finding is not attributed to the unused linter'
grep -F 'main.go:' "$work/leaky.out" >/dev/null || fail 'finding does not name the file'

# JSON output carries the same finding.
rc=0
run -w /work/leaky "$image" run --output.json.path=stdout --output.text.path= ./... \
  >"$work/leaky.json" 2>"$work/leaky.err" || rc=$?
test "$rc" = 1 || fail "leaky json run exit code $rc, expected 1"
grep -F '"FromLinter":"unused"' "$work/leaky.json" >/dev/null || fail 'json report is missing the unused finding'

# Clean module: exit 0 and no findings.
run -w /work/clean "$image" run ./... >"$work/clean.out" 2>&1 ||
  fail 'clean module failed'
if grep -F '(unused)' "$work/clean.out" >/dev/null; then
  fail 'clean module reported an unused finding'
fi

# Invalid configuration is rejected.
printf 'version: "2"\nlinters:\n  enable:\n    - definitely-not-a-linter\n' >"$work/clean/.golangci.yml"
chmod a+r "$work/clean/.golangci.yml"
if run -w /work/clean "$image" run ./... >"$work/badcfg.out" 2>&1; then
  fail 'unknown linter unexpectedly accepted'
fi
grep -F 'definitely-not-a-linter' "$work/badcfg.out" >/dev/null ||
  fail 'unknown linter diagnostic is missing'

printf 'SMOKE PASS image=%s\n' "$image"
