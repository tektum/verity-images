#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
config="$here/../apko.yaml"
version=$(sed -n 's/^    - cue=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail 'could not read the pinned cue version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/cue"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

# Every behavior check runs offline on a read-only root with no capabilities.
run() {
  docker run --rm --network none --read-only --cap-drop=ALL \
    -v "$work/config:/work:ro" "$image" "$@"
}

mkdir -p "$work/config"
chmod 755 "$work/config"

run version >"$work/version" 2>&1 || fail "version failed: $(cat "$work/version")"
# Wolfi rebuilds with patched dependencies, which Go marks as +dirty.
grep -Ex "cue version v$version(\+dirty)?" "$work/version" >/dev/null ||
  fail "version does not report v$version: $(cat "$work/version")"

rc=0
run --definitely-invalid >"$work/invalid" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"

# A schema with defaults, a bounded field and a derived field, plus YAML data.
cat >"$work/config/schema.cue" <<'EOF'
package app

#Service: {
	name:     =~"^[a-z][a-z0-9-]*$"
	port:     int & >=1 & <=65535
	replicas: int | *1
	url:      "http://\(name):\(port)"
}

services: [string]: #Service
EOF
cat >"$work/config/values.cue" <<'EOF'
package app

services: web: {name: "web", port: 8080, replicas: 3}
services: api: {name: "api", port: 9090}
EOF
cat >"$work/config/good.yaml" <<'EOF'
services:
  cache:
    name: cache
    port: 6379
EOF
cat >"$work/config/bad.yaml" <<'EOF'
services:
  cache:
    name: Cache
    port: 70000
EOF
chmod 644 "$work/config"/*

run export schema.cue values.cue --out json >"$work/export.json" 2>"$work/export.err" ||
  fail "export failed: $(cat "$work/export.err")"
jq -e '
  .services.web == {"name":"web","port":8080,"replicas":3,"url":"http://web:8080"} and
  .services.api == {"name":"api","port":9090,"replicas":1,"url":"http://api:9090"}
' "$work/export.json" >/dev/null || fail "unexpected export: $(cat "$work/export.json")"

run export schema.cue values.cue -e services.web.url --out text >"$work/url" 2>&1 ||
  fail "expression export failed: $(cat "$work/url")"
test "$(cat "$work/url")" = 'http://web:8080' || fail "unexpected url: $(cat "$work/url")"

run vet -c=false schema.cue good.yaml >"$work/vet-good" 2>&1 ||
  fail "valid data was rejected: $(cat "$work/vet-good")"

rc=0
run vet -c=false schema.cue bad.yaml >"$work/vet-bad" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid data unexpectedly passed vet'
grep -F 'services.cache.port: invalid value 70000 (out of bound <=65535)' "$work/vet-bad" >/dev/null ||
  fail "port bound violation not reported: $(cat "$work/vet-bad")"
grep -F 'services.cache.name: invalid value "Cache"' "$work/vet-bad" >/dev/null ||
  fail "name pattern violation not reported: $(cat "$work/vet-bad")"

# Conflicting concrete values are an evaluation error, not silently merged.
printf 'x: 1\nx: 2\n' >"$work/config/conflict.cue"
chmod 644 "$work/config/conflict.cue"
rc=0
run eval conflict.cue >"$work/conflict" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'conflicting values unexpectedly evaluated'
grep -F 'x: conflicting values 2 and 1' "$work/conflict" >/dev/null ||
  fail "conflict diagnostic is missing: $(cat "$work/conflict")"

# YAML to CUE import writes through stdout without touching the read-only root.
run import -p app -o - good.yaml >"$work/import.cue" 2>&1 ||
  fail "import failed: $(cat "$work/import.cue")"
for line in 'package app' 'port: 6379'; do
  grep -F "$line" "$work/import.cue" >/dev/null ||
    fail "import output lacks '$line': $(cat "$work/import.cue")"
done

printf 'SMOKE PASS image=%s\n' "$image"
