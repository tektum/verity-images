#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
config="$(dirname "$0")/../apko.yaml"
version=$(sed -n 's/^    - glow=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
work=$(mktemp -d)

trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ -n "$version" ] || fail 'could not read the pinned glow version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/glow"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

docker run --rm --network none "$image" --version >"$work/version" 2>&1 ||
  fail 'version failed'
grep -Ex "glow version $version \([0-9a-f]+\)" "$work/version" >/dev/null ||
  fail "version does not report $version: $(cat "$work/version")"

rc=0
docker run --rm --network none "$image" --definitely-invalid >"$work/flag" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'unknown flag: --definitely-invalid' "$work/flag" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/flag")"

mkdir -p "$work/docs"
cat >"$work/docs/README.md" <<'MD'
# Release notes

Verity renders **Markdown** in the terminal.

- first item
- second item

| Name | Value |
| ---- | ----- |
| alpha | 1 |

```sh
echo rendered-code-block
```
MD
chmod -R a+rX "$work"

# Render a file from the working directory with the plain notty style.
docker run --rm --network none --read-only -v "$work/docs:/work:ro" "$image" \
  -s notty -w 60 README.md >"$work/file.raw" 2>"$work/file.err" ||
  fail "rendering the file failed: $(cat "$work/file.err")"
# glow pads every line to the wrap width; compare without the padding.
sed 's/ *$//' "$work/file.raw" >"$work/file.out"
# glow renders list items with U+2022; keep the script ASCII-only.
bullet=$(printf '\342\200\242')
for expected in '  # Release notes' '  Verity renders **Markdown** in the terminal.' \
  "  $bullet first item" "  $bullet second item" '    echo rendered-code-block'; do
  grep -Fx -- "$expected" "$work/file.out" >/dev/null ||
    fail "rendered output is missing '$expected': $(cat "$work/file.out")"
done
grep -Ex '   Name +\| Value' "$work/file.out" >/dev/null ||
  fail "rendered table header is missing: $(cat "$work/file.out")"
grep -Ex '   alpha +\| 1' "$work/file.out" >/dev/null ||
  fail "rendered table row is missing: $(cat "$work/file.out")"
if grep -F '```' "$work/file.out" >/dev/null; then
  fail 'code fence was not rendered'
fi

# Render from stdin with a colour style and check ANSI styling is emitted.
docker run --rm -i --network none --read-only "$image" -s dark - \
  <"$work/docs/README.md" >"$work/stdin.out" 2>"$work/stdin.err" ||
  fail "rendering stdin failed: $(cat "$work/stdin.err")"
grep -F 'rendered-code-block' "$work/stdin.out" >/dev/null ||
  fail 'stdin output is missing the code block'
esc=$(printf '\033')
grep -F "${esc}[" "$work/stdin.out" >/dev/null || fail 'dark style emitted no ANSI styling'

rc=0
docker run --rm --network none --read-only -v "$work/docs:/work:ro" "$image" \
  -s notty missing.md >"$work/missing" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'missing file unexpectedly succeeded'

printf 'SMOKE PASS\n'
