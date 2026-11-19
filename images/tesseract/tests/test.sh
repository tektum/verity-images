#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
config="$here/../apko.yaml"
version=$(sed -n 's/^    - tesseract=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
tessdata=/usr/share/tessdata
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail 'could not read the pinned tesseract version'

# The container runs as 65532 and writes its outputs into the bind-mounted
# working directory; the root filesystem stays read-only.
chmod 0777 "$work"
cp "$here/fixture.png" "$work/fixture.png"
chmod 0644 "$work/fixture.png"

run() {
  docker run --rm --network none --read-only --cap-drop=ALL \
    -v "$work:/work" "$image" "$@"
}

# expect_failure NAME PATTERN [DOCKER_ARGS...] IMAGE ARGS...: tesseract must
# exit non-zero and print PATTERN.
expect_failure() {
  name=$1
  pattern=$2
  shift 2
  rc=0
  docker run --rm --network none --read-only --cap-drop=ALL -v "$work:/work" \
    "$@" >"$work/$name.out" 2>&1 || rc=$?
  test "$rc" -ne 0 || fail "$name unexpectedly succeeded: $(cat "$work/$name.out")"
  grep -F -- "$pattern" "$work/$name.out" >/dev/null ||
    fail "$name diagnostic '$pattern' is missing: $(cat "$work/$name.out")"
}

# Normalize OCR text output: drop the trailing form feed and blank lines.
text_of() {
  tr -d '\f' <"$1" | sed '/^[[:space:]]*$/d'
}

expected_text='Verity OCR smoke test
Quick brown fox 2026
jumps over the lazy dog'

# OCI contract.
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/tesseract"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["--help"]' ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx "TESSDATA_PREFIX=$tessdata" >/dev/null || fail "TESSDATA_PREFIX is not $tessdata"

# The default command prints usage and succeeds.
docker run --rm --network none --read-only --cap-drop=ALL "$image" >"$work/default" 2>&1 ||
  fail "default command failed: $(cat "$work/default")"
grep -F -- '--list-langs' "$work/default" >/dev/null ||
  fail "default command did not print usage: $(cat "$work/default")"

# --version reports the pinned release and its image libraries.
run --version >"$work/version" 2>&1 || fail "--version failed: $(cat "$work/version")"
test "$(sed -n 1p "$work/version")" = "tesseract $version" ||
  fail "--version does not report tesseract $version: $(cat "$work/version")"
grep -E '^ leptonica-[0-9]' "$work/version" >/dev/null ||
  fail "--version does not report leptonica: $(cat "$work/version")"
grep -F 'libpng ' "$work/version" >/dev/null ||
  fail "--version does not report PNG support: $(cat "$work/version")"

# --list-langs resolves TESSDATA_PREFIX and lists exactly eng and osd.
run --list-langs >"$work/langs" 2>&1 || fail "--list-langs failed: $(cat "$work/langs")"
printf 'List of available languages in "%s/" (2):\neng\nosd\n' "$tessdata" >"$work/langs.expected"
cmp -s "$work/langs" "$work/langs.expected" ||
  fail "unexpected --list-langs output: $(cat "$work/langs")"

# OCR the committed fixture to stdout.
run fixture.png stdout -l eng >"$work/stdout.txt" 2>"$work/stdout.err" ||
  fail "OCR to stdout failed: $(cat "$work/stdout.err")"
test "$(text_of "$work/stdout.txt")" = "$expected_text" ||
  fail "unexpected OCR text: $(cat "$work/stdout.txt")"

# OCR into the writable working directory, as text and as TSV (configs/tsv).
run fixture.png result -l eng >"$work/file.log" 2>&1 ||
  fail "OCR to a file failed: $(cat "$work/file.log")"
test -f "$work/result.txt" || fail 'result.txt was not written into /work'
test "$(stat -c %u "$work/result.txt")" = 65532 || fail 'result.txt is not owned by 65532'
test "$(text_of "$work/result.txt")" = "$expected_text" ||
  fail "unexpected OCR text in result.txt: $(cat "$work/result.txt")"
run fixture.png words -l eng tsv >"$work/tsv.log" 2>&1 ||
  fail "OCR to TSV failed: $(cat "$work/tsv.log")"
for word in Verity OCR Quick 2026 lazy dog; do
  awk -F '\t' -v w="$word" '$1 == 5 && $11 >= 50 && $12 == w { found = 1 } END { exit !found }' \
    "$work/words.tsv" || fail "TSV has no confident word '$word': $(cat "$work/words.tsv")"
done

# The image's own /work is writable by the runtime user without a bind mount.
docker run --rm -i --network none --cap-drop=ALL "$image" stdin own -l eng \
  <"$here/fixture.png" >"$work/own.log" 2>&1 ||
  fail "OCR into the image's own /work failed: $(cat "$work/own.log")"

# The osd model detects orientation and script.
run fixture.png stdout --psm 0 >"$work/osd" 2>&1 || fail "OSD failed: $(cat "$work/osd")"
grep -Fx 'Orientation in degrees: 0' "$work/osd" >/dev/null ||
  fail "OSD did not report upright orientation: $(cat "$work/osd")"
grep -Fx 'Script: Latin' "$work/osd" >/dev/null ||
  fail "OSD did not detect Latin script: $(cat "$work/osd")"

# Negative cases: an absent language, a missing input, and a TESSDATA_PREFIX
# override to an existing directory without models, which tesseract must honor.
expect_failure missing-lang "Failed loading language 'deu'" "$image" fixture.png stdout -l deu
expect_failure missing-input 'cannot read input file missing.png' "$image" missing.png stdout
expect_failure wrong-prefix "Failed loading language 'eng'" \
  -e TESSDATA_PREFIX=/work "$image" fixture.png stdout -l eng

printf 'SMOKE PASS image=%s\n' "$image"
