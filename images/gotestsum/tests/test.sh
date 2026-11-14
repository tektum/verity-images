#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
config="$here/../apko.yaml"
version=$(sed -n 's/^    - gotestsum=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
go_version=$(sed -n 's/^    - go-[0-9.]*=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail 'could not read the pinned gotestsum version'
[ -n "$go_version" ] || fail 'could not read the pinned Go version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/gotestsum"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

# The bundled toolchain is the only one gotestsum may use: a module that asks
# for a newer Go fails clearly instead of downloading an unscanned toolchain.
docker image inspect --format '{{json .Config.Env}}' "$image" >"$work/env"
for var in GOTOOLCHAIN=local GOPATH=/home/nonroot/go GOCACHE=/home/nonroot/.cache/go-build; do
  jq -e --arg v "$var" 'index($v) != null' "$work/env" >/dev/null || fail "image environment lacks $var"
done

# Offline on a read-only root with no capabilities. The module is mounted
# read-only at the working directory; reports go to /out and the build cache
# lives on an exec tmpfs, where go test also links the test binaries.
mkdir -p "$work/src" "$work/out"
chmod 777 "$work/out"
run() {
  docker run --rm --network none --read-only --cap-drop=ALL \
    --tmpfs /tmp:exec,mode=1777 -e GOCACHE=/tmp/go-build \
    -v "$work/src:/work:ro" -v "$work/out:/out" "$image" "$@"
}

run --version >"$work/version" 2>&1 || fail "version failed: $(cat "$work/version")"
# Wolfi rebuilds with patched dependencies, which Go marks as +dirty.
grep -Ex "gotestsum version v$version(\+dirty)?" "$work/version" >/dev/null ||
  fail "version does not report v$version: $(cat "$work/version")"

docker run --rm --network none --read-only --entrypoint go "$image" version >"$work/go" 2>&1 ||
  fail "go version failed: $(cat "$work/go")"
grep -Eq "^go version go$go_version linux/(amd64|arm64)$" "$work/go" ||
  fail "bundled Go is not $go_version: $(cat "$work/go")"

status=0
run --definitely-invalid >"$work/invalid" 2>&1 || status=$?
test "$status" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"

# A dependency-free module with a passing, a failing and a flaky package.
mkdir -p "$work/src/calc" "$work/src/broken" "$work/src/flaky"
cat >"$work/src/go.mod" <<'EOF'
module example.test/smoke

go 1.24
EOF
cat >"$work/src/calc/calc.go" <<'EOF'
package calc

func Add(a, b int) int { return a + b }
EOF
cat >"$work/src/calc/calc_test.go" <<'EOF'
package calc

import (
	"testing"
	"time"
)

func TestAdd(t *testing.T) {
	time.Sleep(30 * time.Millisecond) // slow enough for tool slowest
	if got := Add(2, 3); got != 5 {
		t.Fatalf("Add(2, 3) = %d", got)
	}
}

func TestAddTable(t *testing.T) {
	for _, c := range []struct{ a, b, want int }{{1, 1, 2}, {-1, 1, 0}} {
		t.Run("case", func(t *testing.T) {
			if got := Add(c.a, c.b); got != c.want {
				t.Fatalf("Add(%d, %d) = %d", c.a, c.b, got)
			}
		})
	}
}
EOF
cat >"$work/src/broken/broken_test.go" <<'EOF'
package broken

import "testing"

func TestGood(t *testing.T) {}

func TestBad(t *testing.T) {
	t.Fatal("verity expected failure")
}
EOF
# Fails on its first run and passes once a marker exists in the shared /tmp.
cat >"$work/src/flaky/flaky_test.go" <<'EOF'
package flaky

import (
	"os"
	"testing"
)

func TestFlaky(t *testing.T) {
	const marker = "/tmp/verity-flaky-marker"
	if _, err := os.Stat(marker); err != nil {
		if err := os.WriteFile(marker, nil, 0o600); err != nil {
			t.Fatal(err)
		}
		t.Fatal("verity first attempt fails")
	}
}
EOF
chmod -R a+rX "$work/src"

run --format testname --junitfile /out/pass.xml --jsonfile /out/pass.json -- ./calc/... \
  >"$work/pass" 2>&1 || fail "passing package failed: $(cat "$work/pass")"
grep -E '^PASS calc\.TestAdd \(' "$work/pass" >/dev/null || fail "TestAdd is not reported: $(cat "$work/pass")"
grep -E '^PASS calc\.TestAddTable/case#01 \(' "$work/pass" >/dev/null ||
  fail "subtest is not reported: $(cat "$work/pass")"
grep -E '^DONE 4 tests in ' "$work/pass" >/dev/null || fail "unexpected summary: $(cat "$work/pass")"
grep -E '<testsuite tests="4" failures="0" ' "$work/out/pass.xml" >/dev/null ||
  fail "JUnit report does not record 4 passing tests: $(cat "$work/out/pass.xml")"
grep -F '"Action":"pass","Package":"example.test/smoke/calc","Test":"TestAdd"' "$work/out/pass.json" \
  >/dev/null || fail 'test2json log is missing the TestAdd pass event'

# The tool subcommand reads the recorded log back.
run tool slowest --jsonfile /out/pass.json --threshold 25ms >"$work/slowest" 2>&1 ||
  fail "tool slowest failed: $(cat "$work/slowest")"
grep -E '^example\.test/smoke/calc TestAdd [0-9.]+m?s$' "$work/slowest" >/dev/null ||
  fail "tool slowest does not list TestAdd: $(cat "$work/slowest")"
if grep -F 'TestAddTable' "$work/slowest" >/dev/null; then
  fail "tool slowest lists a test under the threshold: $(cat "$work/slowest")"
fi

# Negative: a failing test makes gotestsum exit 1 and the reports record it.
status=0
run --format standard-quiet --junitfile /out/fail.xml -- ./broken/... >"$work/fail" 2>&1 || status=$?
test "$status" = 1 || fail "failing package exited $status, want 1: $(cat "$work/fail")"
grep -F 'verity expected failure' "$work/fail" >/dev/null || fail "failure message is missing: $(cat "$work/fail")"
grep -E '^DONE 2 tests, 1 failure in ' "$work/fail" >/dev/null ||
  fail "unexpected failure summary: $(cat "$work/fail")"
grep -E '<testsuite tests="2" failures="1" ' "$work/out/fail.xml" >/dev/null ||
  fail "JUnit report does not record the failure: $(cat "$work/out/fail.xml")"
grep -F '<testcase classname="example.test/smoke/broken" name="TestBad"' "$work/out/fail.xml" >/dev/null ||
  fail 'JUnit report is missing the TestBad case'

# A compile error is a failure too, not an empty pass.
mkdir -p "$work/src/nocompile"
printf 'package nocompile\n\nfunc broken() int { return "x" }\n' >"$work/src/nocompile/x.go"
chmod -R a+rX "$work/src"
status=0
run -- ./nocompile/... >"$work/nocompile" 2>&1 || status=$?
test "$status" -ne 0 || fail 'a package that does not compile passed'
grep -F 'cannot use "x"' "$work/nocompile" >/dev/null ||
  fail "compile error is not shown: $(cat "$work/nocompile")"

# Negative: a module that requires a newer Go fails with the local toolchain pinned.
mkdir -p "$work/newgo"
printf 'module example.test/newgo\n\ngo 1.999\n' >"$work/newgo/go.mod"
printf 'package newgo\n' >"$work/newgo/x.go"
chmod -R a+rX "$work/newgo"
status=0
docker run --rm --network none --read-only --cap-drop=ALL --tmpfs /tmp:exec,mode=1777 \
  -e GOCACHE=/tmp/go-build -v "$work/newgo:/work:ro" "$image" -- ./... >"$work/newgo.log" 2>&1 || status=$?
test "$status" -ne 0 || fail 'a module requiring a newer Go unexpectedly passed'
grep -F 'requires go >= 1.999' "$work/newgo.log" >/dev/null ||
  fail "newer Go requirement diagnostic is missing: $(cat "$work/newgo.log")"
grep -F 'GOTOOLCHAIN=local' "$work/newgo.log" >/dev/null ||
  fail "the toolchain was not pinned to the local one: $(cat "$work/newgo.log")"

# --rerun-fails reruns only the failed test and succeeds when it then passes.
run --format testname --rerun-fails=2 --packages ./flaky/... -- -count=1 >"$work/rerun" 2>&1 ||
  fail "rerun of the flaky test failed: $(cat "$work/rerun")"
grep -E '^FAIL flaky\.TestFlaky ' "$work/rerun" >/dev/null || fail "first failure is not shown: $(cat "$work/rerun")"
grep -E '^PASS flaky\.TestFlaky ' "$work/rerun" >/dev/null || fail "rerun pass is not shown: $(cat "$work/rerun")"
grep -E '^DONE 2 runs, 2 tests, 1 failure in ' "$work/rerun" >/dev/null ||
  fail "unexpected rerun summary: $(cat "$work/rerun")"

echo 'SMOKE PASS'
