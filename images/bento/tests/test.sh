#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml" | head -n 1)
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/bento"]' ] || fail 'unexpected entrypoint'

version=$(docker run --rm --network none "$image" --version)
printf '%s\n' "$version" | grep -qx "Version: ${expected_version}" || fail "unexpected Bento version: $version"

cat >"$work/pipeline.yaml" <<'EOF'
input:
  stdin:
    scanner:
      lines: {}
pipeline:
  processors:
    - mapping: |
        root.name = this.name.uppercase()
        root.total = this.items.map_each(i -> i.price * i.qty).sum()
    - switch:
        - check: this.total > 10
          processors:
            - mapping: 'root = this.merge({"tier": "large"})'
        - processors:
            - mapping: 'root = this.merge({"tier": "small"})'
output:
  stdout:
    codec: lines
logger:
  level: warn
EOF
cat >"$work/invalid.yaml" <<'EOF'
input:
  stdin: {}
pipeline:
  processors:
    - mapping: root = this.(
output:
  stdout: {}
EOF
chmod -R a+rX "$work"

docker run --rm --network none -v "$work:/work:ro" "$image" lint /work/pipeline.yaml ||
  fail 'valid pipeline failed lint'
if docker run --rm --network none -v "$work:/work:ro" "$image" lint /work/invalid.yaml >/dev/null 2>&1; then
  fail 'invalid pipeline unexpectedly passed lint'
fi

output=$(printf '%s\n' \
  '{"name":"alpha","items":[{"price":2,"qty":3},{"price":1,"qty":1}]}' \
  '{"name":"beta","items":[{"price":5,"qty":4}]}' |
  docker run --rm -i --network none -v "$work:/work:ro" "$image" -c /work/pipeline.yaml)
expected='{"name":"ALPHA","tier":"small","total":7}
{"name":"BETA","tier":"large","total":20}'
[ "$output" = "$expected" ] || fail "unexpected pipeline output: $output"

if printf '%s\n' '{}' | docker run --rm -i --network none -v "$work:/work:ro" "$image" \
  -c /work/invalid.yaml >/dev/null 2>&1; then
  fail 'invalid pipeline unexpectedly ran'
fi

printf 'SMOKE PASS version=%s\n' "$expected_version"
