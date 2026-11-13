#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
config="$here/../apko.yaml"
version=$(sed -n 's/^    - mage=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail 'could not read the pinned mage version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/mage"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

# Offline on a read-only root with no capabilities: only the mounted project
# and an executable tmpfs home (Go build cache, compiled magefile cache) are
# writable.
run() {
  dir=$1
  shift
  docker run --rm --network none --read-only --cap-drop=ALL \
    --tmpfs /home/nonroot:exec,uid=65532,gid=65532,mode=0755 \
    --tmpfs /tmp:mode=1777 \
    -v "$work/$dir:/work" "$image" "$@"
}

mkdir -p "$work/project" "$work/empty"
chmod 777 "$work/project" "$work/empty"

run empty -version >"$work/version" 2>&1 || fail "version failed: $(cat "$work/version")"
# Wolfi rebuilds with patched dependencies, which Go marks as +dirty.
grep -Ex "Mage Build Tool v$version(\+dirty)?" "$work/version" >/dev/null ||
  fail "version does not report v$version: $(cat "$work/version")"
grep -E '^built with: go1\.[0-9]+' "$work/version" >/dev/null ||
  fail "version does not report the Go toolchain: $(cat "$work/version")"

rc=0
run empty -definitely-invalid >"$work/invalid" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"

rc=0
run empty >"$work/nomagefile" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'a directory without a magefile unexpectedly succeeded'
grep -F 'No .go files marked with the mage build tag in this directory.' "$work/nomagefile" >/dev/null ||
  fail "missing magefile diagnostic is missing: $(cat "$work/nomagefile")"

# A magefile with a default target, a dependency chain, a namespaced argument
# target and a failing target. Building it needs the bundled Go toolchain.
cat >"$work/project/magefile.go" <<'EOF'
//go:build mage

package main

import (
	"errors"
	"fmt"
	"os"
	"runtime"
	"strings"
)

// Default target to run when none is specified.
var Default = Build

// Generate writes the generated source file.
func Generate() error {
	return os.WriteFile("generated.txt", []byte("generated\n"), 0o644)
}

// Build compiles the project after generating sources.
func Build() error {
	if err := Generate(); err != nil {
		return err
	}
	data, err := os.ReadFile("generated.txt")
	if err != nil {
		return err
	}
	out := fmt.Sprintf("built from %s with %s", strings.TrimSpace(string(data)), runtime.Version())
	return os.WriteFile("build.txt", []byte(out+"\n"), 0o644)
}

// Greet prints a greeting for the given name.
func Greet(name string) {
	fmt.Printf("hello %s\n", name)
}

// Broken always fails.
func Broken() error {
	return errors.New("intentional failure")
}
EOF
chmod 644 "$work/project/magefile.go"

run project -l >"$work/list" 2>&1 || fail "listing targets failed: $(cat "$work/list")"
for line in 'build*      compiles the project after generating sources.' \
  'greet       prints a greeting for the given name.' \
  'broken      always fails.' '* default target'; do
  grep -F "$line" "$work/list" >/dev/null || fail "target listing lacks '$line': $(cat "$work/list")"
done

run project >"$work/default" 2>&1 || fail "default target failed: $(cat "$work/default")"
test "$(cat "$work/project/generated.txt")" = generated || fail 'dependency target did not run'
grep -Ex 'built from generated with go1\.[0-9.]+' "$work/project/build.txt" >/dev/null ||
  fail "unexpected build output: $(cat "$work/project/build.txt")"

run project greet verity >"$work/greet" 2>&1 || fail "argument target failed: $(cat "$work/greet")"
grep -Fx 'hello verity' "$work/greet" >/dev/null || fail "unexpected greeting: $(cat "$work/greet")"

rc=0
run project broken >"$work/broken" 2>&1 || rc=$?
test "$rc" -eq 1 || fail "failing target exited $rc, expected 1"
grep -Fx 'Error: intentional failure' "$work/broken" >/dev/null ||
  fail "failing target error is missing: $(cat "$work/broken")"

rc=0
run project nope >"$work/unknown" 2>&1 || rc=$?
test "$rc" -eq 2 || fail "unknown target exited $rc, expected 2"
grep -F 'Unknown target specified: "nope"' "$work/unknown" >/dev/null ||
  fail "unknown target diagnostic is missing: $(cat "$work/unknown")"

# -compile writes a standalone static binary that runs without the toolchain.
run project -compile /work/magebin >"$work/compile" 2>&1 || fail "compile failed: $(cat "$work/compile")"
docker run --rm --network none --read-only --cap-drop=ALL -v "$work/project:/work" \
  --entrypoint /work/magebin "$image" greet compiled >"$work/compiled" 2>&1 ||
  fail "compiled binary failed: $(cat "$work/compiled")"
grep -Fx 'hello compiled' "$work/compiled" >/dev/null ||
  fail "unexpected compiled output: $(cat "$work/compiled")"

printf 'SMOKE PASS image=%s\n' "$image"
