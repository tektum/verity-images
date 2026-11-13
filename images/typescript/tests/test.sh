#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
config="$(dirname "$0")/../apko.yaml"
version=$(sed -n 's/^    - typescript=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
work=$(mktemp -d)

trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ -n "$version" ] || fail 'could not read the pinned typescript version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/tsc"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

docker run --rm --network none "$image" --version >"$work/version" 2>&1 ||
  fail 'version failed'
grep -Fx "Version $version" "$work/version" >/dev/null ||
  fail "version does not report $version: $(cat "$work/version")"

rc=0
docker run --rm --network none "$image" --definitely-invalid >"$work/flag" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F "error TS5023: Unknown compiler option '--definitely-invalid'." "$work/flag" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/flag")"

mkdir -p "$work/good/src" "$work/good/dist" "$work/bad/src"
cat >"$work/good/tsconfig.json" <<'JSON'
{
  "compilerOptions": {
    "target": "es2022",
    "module": "commonjs",
    "strict": true,
    "rootDir": "src",
    "outDir": "dist",
    "declaration": true
  },
  "include": ["src"]
}
JSON
cp "$work/good/tsconfig.json" "$work/bad/tsconfig.json"
cat >"$work/good/src/point.ts" <<'TS'
export interface Point {
  x: number;
  y: number;
}

export enum Axis {
  X = 1,
  Y,
}

export const add = (a: Point, b: Point): Point => ({ x: a.x + b.x, y: a.y + b.y });
TS
cat >"$work/bad/src/point.ts" <<'TS'
export const count: number = "not a number";
TS
chmod -R a+rX "$work"
# The compiler runs as 65532 and writes only into dist.
chmod 0777 "$work/good/dist"

docker run --rm --network none --read-only -v "$work/good:/work" "$image" -p . \
  >"$work/good.out" 2>&1 || fail "compiling the valid project failed: $(cat "$work/good.out")"
test -f "$work/good/dist/point.js" || fail 'point.js was not emitted'
test -f "$work/good/dist/point.d.ts" || fail 'point.d.ts was not emitted'
grep -F 'const add = (a, b) => ({ x: a.x + b.x, y: a.y + b.y });' "$work/good/dist/point.js" \
  >/dev/null || fail "emitted JavaScript is unexpected: $(cat "$work/good/dist/point.js")"
grep -F 'Axis[Axis["Y"] = 2] = "Y";' "$work/good/dist/point.js" >/dev/null ||
  fail "emitted enum is unexpected: $(cat "$work/good/dist/point.js")"
grep -F 'export declare const add: (a: Point, b: Point) => Point;' "$work/good/dist/point.d.ts" \
  >/dev/null || fail "emitted declarations are unexpected: $(cat "$work/good/dist/point.d.ts")"
if grep -F 'interface' "$work/good/dist/point.js" >/dev/null; then
  fail 'type-only syntax leaked into the emitted JavaScript'
fi

rc=0
docker run --rm --network none --read-only -v "$work/bad:/work:ro" "$image" -p . --noEmit \
  >"$work/bad.out" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'the type error unexpectedly compiled'
grep -F "src/point.ts(1,14): error TS2322: Type 'string' is not assignable to type 'number'." \
  "$work/bad.out" >/dev/null || fail "type error diagnostic is missing: $(cat "$work/bad.out")"

printf 'SMOKE PASS\n'
