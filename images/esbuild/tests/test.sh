#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf '%s\n' 'package version not found' >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

esbuild() {
  docker run --rm -i --network none -v "$work:/work" -w /work "$image" "$@"
}

user=$(docker image inspect -f '{{.Config.User}}' "$image")
[ "$user" = 65532 ] || fail "image user is $user, want 65532"
entrypoint=$(docker image inspect -f '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' "$image")
[ "$entrypoint" = '["/usr/bin/esbuild"] null' ] || fail "unexpected entrypoint: $entrypoint"
[ "$(docker run --rm "$image" --version)" = "$expected_version" ] ||
  fail "unexpected version, want $expected_version"

if docker run --rm "$image" --no-such-flag >/dev/null 2>&1; then
  fail 'unknown flag was accepted'
fi

# The image user (65532) writes the bundle into the mounted work directory.
chmod 777 "$work"

# Bundle a TypeScript entry point with an import into a minified ESM file.
mkdir -p "$work/src" "$work/dist"
chmod 777 "$work/dist"
cat >"$work/src/util.ts" <<'EOF'
export function greet(name: string): string {
  return `hello ${name}`
}
export const unused = 'tree-shaken-away'
EOF
cat >"$work/src/index.ts" <<'EOF'
import { greet } from './util'
console.log(greet('verity'))
EOF
esbuild src/index.ts --bundle --minify --format=esm --platform=neutral \
  --outfile=dist/out.js --log-level=warning
[ -s "$work/dist/out.js" ] || fail 'bundle output was not written'
# shellcheck disable=SC2016  # the bundled template literal contains a literal ${
grep -F 'hello ${' "$work/dist/out.js" >/dev/null || fail 'bundle does not contain the imported function'
if grep -F 'tree-shaken-away' "$work/dist/out.js" >/dev/null; then
  fail 'unused export was not tree-shaken'
fi
if grep -F ': string' "$work/dist/out.js" >/dev/null; then
  fail 'TypeScript annotations were not stripped'
fi

# Transform from stdin.
[ "$(printf 'let a: number = 1 + 2\n' | esbuild --loader=ts --minify-syntax)" = 'let a = 3;' ] ||
  fail 'stdin transform produced unexpected output'

# A syntax error fails the build.
printf 'export const = 1\n' >"$work/src/bad.ts"
if esbuild src/bad.ts --bundle --outfile=dist/bad.js --log-level=silent; then
  fail 'syntax error was accepted'
fi

printf '%s\n' "esbuild $expected_version smoke test passed"
