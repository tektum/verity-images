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

expected_version=$(sed -n 's/^    - yara-x=\([0-9.]*\)-r[0-9]*$/\1/p' "$here/../apko.yaml")
[ -n "$expected_version" ] || fail 'could not read the pinned yara-x version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/yr"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

# Fixtures: one rule that needs both a text and a wildcard hex pattern, one rule
# that can never match these small files, a file with both patterns, a file
# with only the text pattern, and a file with neither.
mkdir -p "$work/files"
cat >"$work/rules.yar" <<'EOF'
rule verity_marker {
  strings:
    $text = "VERITY-SMOKE-MARKER"
    $hex = { DE AD ?? EF }
  condition:
    $text and $hex
}

rule verity_huge {
  condition:
    filesize > 1MB
}
EOF
printf 'head VERITY-SMOKE-MARKER \336\255\001\357 tail\n' >"$work/files/hit.bin"
printf 'head VERITY-SMOKE-MARKER only text\n' >"$work/files/partial.txt"
printf 'nothing to see here\n' >"$work/files/miss.txt"
cat >"$work/broken.yar" <<'EOF'
rule broken {
  condition:
    $missing
}
EOF
chmod 0777 "$work"
chmod 0755 "$work/files"
chmod 0644 "$work/rules.yar" "$work/broken.yar" "$work/files/"*

yr() {
  docker run --rm --network none --read-only --cap-drop ALL -v "$work:/work" "$image" "$@"
}

yr --version >"$work/version" || fail 'yr --version failed'
grep -Fx "yara-x-cli $expected_version" "$work/version" >/dev/null ||
  fail "yr --version does not report $expected_version: $(cat "$work/version")"

if yr --definitely-invalid >"$work/invalid" 2>&1; then
  fail 'invalid flag unexpectedly succeeded'
fi
grep -F "unexpected argument '--definitely-invalid' found" "$work/invalid" >/dev/null ||
  fail 'invalid flag diagnostic is missing'

yr check rules.yar >"$work/check" 2>&1 || fail "yr check failed: $(cat "$work/check")"
grep -F '[ PASS ] rules.yar' "$work/check" >/dev/null || fail 'yr check did not pass the rules'

# Negative: a rule that references an undeclared pattern does not compile.
if yr check broken.yar >"$work/broken" 2>&1; then
  fail 'broken rule unexpectedly passed yr check'
fi
grep -F "unknown pattern \`\$missing\`" "$work/broken" >/dev/null ||
  fail "broken rule diagnostic is missing: $(cat "$work/broken")"
if yr scan broken.yar files >"$work/broken-scan" 2>&1; then
  fail 'scan with a broken rule unexpectedly succeeded'
fi

# Match: the file with both patterns, with the matched offsets and bytes.
yr scan -s rules.yar files/hit.bin >"$work/hit" 2>&1 || fail "scan of hit.bin failed: $(cat "$work/hit")"
grep -Fx 'verity_marker files/hit.bin' "$work/hit" >/dev/null ||
  fail "hit.bin did not match verity_marker: $(cat "$work/hit")"
grep -Fx "0x5:19:\$text: VERITY-SMOKE-MARKER" "$work/hit" >/dev/null ||
  fail "text pattern offset is wrong: $(cat "$work/hit")"
grep -Fx "0x19:4:\$hex: de ad 01 ef" "$work/hit" >/dev/null ||
  fail "hex pattern offset is wrong: $(cat "$work/hit")"
if grep -F verity_huge "$work/hit" >/dev/null; then
  fail 'verity_huge unexpectedly matched'
fi

# Non-match: neither the text-only file nor the empty-handed file matches.
yr scan rules.yar files/miss.txt >"$work/miss" 2>&1 || fail 'scan of miss.txt failed'
if [ -s "$work/miss" ]; then
  fail "miss.txt unexpectedly matched: $(cat "$work/miss")"
fi
yr scan rules.yar files/partial.txt >"$work/partial" 2>&1 || fail 'scan of partial.txt failed'
if [ -s "$work/partial" ]; then
  fail "partial.txt unexpectedly matched: $(cat "$work/partial")"
fi

# Directory scan: exactly one match across the three files.
yr scan rules.yar files >"$work/dir" 2>&1 || fail 'directory scan failed'
test "$(cat "$work/dir")" = 'verity_marker files/hit.bin' ||
  fail "directory scan is unexpected: $(cat "$work/dir")"

# --negate reports the rules that did not match miss.txt.
yr scan --negate rules.yar files/miss.txt >"$work/negate" 2>&1 || fail 'negated scan failed'
test "$(sort "$work/negate" | tr '\n' ' ')" = 'verity_huge files/miss.txt verity_marker files/miss.txt ' ||
  fail "negated scan is unexpected: $(cat "$work/negate")"

# Compiled rules: compile, then scan with -C and JSON output.
yr compile rules.yar -o rules.yarc >"$work/compile" 2>&1 || fail "yr compile failed: $(cat "$work/compile")"
yr scan -C --output-format json rules.yarc files/hit.bin >"$work/json" ||
  fail 'scan with compiled rules failed'
jq -e --arg v "$expected_version" '.version == $v
  and (.matches | length == 1)
  and .matches[0].rule == "verity_marker"
  and .matches[0].file == "/work/files/hit.bin"' "$work/json" >/dev/null ||
  fail "compiled-rule JSON output is unexpected: $(cat "$work/json")"

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$expected_version"
