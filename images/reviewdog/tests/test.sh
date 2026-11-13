#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^    - reviewdog=\([0-9][0-9.]*\)-r[0-9]*$/\1/p' \
  "$(dirname "$0")/../apko.yaml")
[ -n "$expected_version" ] || { printf '%s\n' 'reviewdog package pin not found' >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# The repository is owned by the runner user, not 65532, so the container
# trusts it explicitly, as a CI job mounting a checkout would.
run() {
  timeout 60 docker run --rm -i --network none -v "$work/repo:/work" \
    -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0=/work \
    "$@"
}

user=$(docker image inspect -f '{{.Config.User}}' "$image")
[ "$user" = 65532 ] || fail "image user is $user, want 65532"
entrypoint=$(docker image inspect -f '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' "$image")
[ "$entrypoint" = '["/usr/bin/reviewdog"] null' ] || fail "unexpected entrypoint: $entrypoint"
workdir=$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")
[ "$workdir" = /work ] || fail "unexpected working directory: $workdir"

mkdir "$work/repo"
version=$(run "$image" -version </dev/null 2>&1) || fail "reviewdog -version failed: $version"
[ "$version" = "$expected_version" ] || fail "unexpected version '$version', want $expected_version"

run "$image" -list </dev/null >"$work/list.txt" 2>&1 || { cat "$work/list.txt" >&2; fail 'reviewdog -list failed'; }
grep -E '^golangci-lint[[:space:]]' "$work/list.txt" >/dev/null ||
  { cat "$work/list.txt" >&2; fail 'reviewdog -list lacks the golangci-lint errorformat'; }

# A committed file plus one uncommitted added line. Findings are reported for
# both lines; diff filtering must keep only the added one.
git -C "$work/repo" init -q
git -C "$work/repo" config user.email smoke@example.invalid
git -C "$work/repo" config user.name smoke
printf 'package main\n\nfunc main() {\n\told := 1\n}\n' >"$work/repo/main.go"
git -C "$work/repo" add main.go
git -C "$work/repo" commit -q -m initial
printf 'package main\n\nfunc main() {\n\told := 1\n\tadded := 2\n}\n' >"$work/repo/main.go"
chmod -R a+rX "$work/repo"
cat >"$work/findings.txt" <<'EOF'
main.go:4:2: declared and not used: old
main.go:5:2: declared and not used: added
EOF

run "$image" -efm='%f:%l:%c: %m' -name=vet -reporter=local -filter-mode=nofilter \
  <"$work/findings.txt" >"$work/all.txt" 2>&1 ||
  { cat "$work/all.txt" >&2; fail 'reviewdog nofilter run failed'; }
grep -Fx 'main.go:4:2: declared and not used: old' "$work/all.txt" >/dev/null ||
  { cat "$work/all.txt" >&2; fail 'nofilter dropped the unchanged-line finding'; }
grep -Fx 'main.go:5:2: declared and not used: added' "$work/all.txt" >/dev/null ||
  { cat "$work/all.txt" >&2; fail 'nofilter dropped the added-line finding'; }

run "$image" -efm='%f:%l:%c: %m' -name=vet -reporter=local -diff='git diff' -filter-mode=added \
  <"$work/findings.txt" >"$work/added.txt" 2>&1 ||
  { cat "$work/added.txt" >&2; fail 'reviewdog diff-filtered run failed'; }
grep -Fx 'main.go:5:2: declared and not used: added' "$work/added.txt" >/dev/null ||
  { cat "$work/added.txt" >&2; fail 'diff filter dropped the added-line finding'; }
if grep -F 'not used: old' "$work/added.txt" >/dev/null; then
  cat "$work/added.txt" >&2
  fail 'diff filter reported a finding on an unchanged line'
fi

# -fail-level turns an error finding into a failing exit; rdjsonl input is parsed.
if run "$image" -f=rdjsonl -name=rd -reporter=local -filter-mode=nofilter -fail-level=error \
  >"$work/fail.txt" 2>&1 <<'EOF'
{"message":"rdjsonl finding","location":{"path":"main.go","range":{"start":{"line":5,"column":2}}},"severity":"ERROR"}
EOF
then
  fail 'error finding did not fail with -fail-level=error'
fi
grep -F 'found at least one issue with severity greater than or equal to the given level: error' \
  "$work/fail.txt" >/dev/null || { cat "$work/fail.txt" >&2; fail '-fail-level=error did not explain the failure'; }
grep -F '"message":"rdjsonl finding"' "$work/fail.txt" >/dev/null ||
  { cat "$work/fail.txt" >&2; fail 'rdjsonl finding was not reported'; }
# A warning stays below -fail-level=error.
run "$image" -f=rdjsonl -name=rd -reporter=local -filter-mode=nofilter -fail-level=error \
  >"$work/warn.txt" 2>&1 <<'EOF' || { cat "$work/warn.txt" >&2; fail 'warning finding failed -fail-level=error'; }
{"message":"rdjsonl warning","location":{"path":"main.go","range":{"start":{"line":4,"column":2}}},"severity":"WARNING"}
EOF

if run "$image" -f=no-such-format -reporter=local </dev/null >"$work/badfmt.txt" 2>&1; then
  fail 'unknown input format was accepted'
fi
grep -F 'no-such-format' "$work/badfmt.txt" >/dev/null ||
  { cat "$work/badfmt.txt" >&2; fail 'unknown format error does not name it'; }
if run "$image" -no-such-flag </dev/null >"$work/flag.txt" 2>&1; then
  fail 'unknown flag was accepted'
fi
grep -F 'no-such-flag' "$work/flag.txt" >/dev/null ||
  { cat "$work/flag.txt" >&2; fail 'unknown flag error does not name the flag'; }

printf '%s\n' "reviewdog $expected_version smoke test passed"
