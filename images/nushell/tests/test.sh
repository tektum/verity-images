#!/bin/sh
# shellcheck disable=SC2016 # Nushell programs are passed literally to the container.
set -eu

image=${1:?usage: test.sh IMAGE}
config="$(dirname "$0")/../apko.yaml"
version=$(sed -n 's/^    - nushell=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
work=$(mktemp -d)

trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ -n "$version" ] || fail 'could not read the pinned nushell version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/nu"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

run() {
  docker run --rm --network none --read-only --tmpfs /tmp:rw,mode=1777 \
    -v "$work/data:/work:ro" "$image" "$@"
}

mkdir -p "$work/data"
cat >"$work/data/people.json" <<'JSON'
[
  {"name": "ada", "age": 36, "team": "core"},
  {"name": "bob", "age": 25, "team": "web"},
  {"name": "cy", "age": 41, "team": "core"}
]
JSON
cat >"$work/data/sales.csv" <<'CSV'
region,amount
north,10
south,5
north,7
CSV
cat >"$work/data/script.nu" <<'NU'
def main [name: string, --count: int = 2] {
  1..$count | each {|i| $"($name)-($i)" } | str join ","
}
NU
chmod -R a+rX "$work"

out=$(run --version) || fail 'version failed'
test "$out" = "$version" || fail "version does not report $version: $out"

out=$(run -c '[1 2 3] | math sum') || fail 'arithmetic pipeline failed'
test "$out" = 6 || fail "unexpected sum: $out"

# Structured data: filter, sort and reshape JSON from the working directory.
out=$(run -c 'open people.json | where age > 30 | sort-by age --reverse | get name | to json --raw') ||
  fail 'JSON pipeline failed'
test "$out" = '["cy","ada"]' || fail "unexpected JSON pipeline output: $out"

out=$(run -c 'open sales.csv | group-by region --to-table | each {|g| {region: $g.region, total: ($g.items.amount | math sum)} } | sort-by region | to csv') ||
  fail 'CSV aggregation failed'
expected=$(printf 'region,total\nnorth,17\nsouth,5')
test "$out" = "$expected" || fail "unexpected CSV aggregation: $out"

# Scripts with a typed main signature and flags.
out=$(run script.nu web --count 3) || fail 'script run failed'
test "$out" = 'web-1,web-2,web-3' || fail "unexpected script output: $out"

# Negative: a raised error and a type error both exit non-zero with diagnostics.
rc=0
run -c 'error make {msg: "smoke-boom"}' >"$work/err" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'error make unexpectedly succeeded'
grep -F 'smoke-boom' "$work/err" >/dev/null || fail 'error diagnostic is missing'

rc=0
run script.nu web --count notanumber >"$work/type" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'mistyped flag unexpectedly succeeded'
grep -Fi 'int' "$work/type" >/dev/null || fail 'type diagnostic is missing'

rc=0
run -c 'open missing.json' >"$work/missing" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'opening a missing file unexpectedly succeeded'

printf 'SMOKE PASS\n'
