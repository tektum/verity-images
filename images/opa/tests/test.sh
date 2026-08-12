#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
tmp=$(mktemp -d)
container=
cleanup() {
  [ -z "$container" ] || docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM
chmod 755 "$tmp"

test "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532 || {
  printf '%s\n' 'image user is not 65532' >&2
  exit 1
}
test "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/opa"]' || {
  printf '%s\n' 'unexpected image entrypoint' >&2
  exit 1
}

container=$(docker create "$image" version)
docker cp "$container:/etc/ssl/certs/ca-certificates.crt" "$tmp/ca-certificates.crt" >/dev/null
[ -s "$tmp/ca-certificates.crt" ] || {
  printf '%s\n' 'system CA bundle is missing' >&2
  exit 1
}
docker rm "$container" >/dev/null
container=

cat >"$tmp/policy.rego" <<'EOF'
package authz

allow if input.role == "admin"
EOF
printf '%s\n' '{"role":"admin"}' >"$tmp/input.json"
actual=$(docker run --rm -v "$tmp:/work:ro" "$image" eval --format raw \
  --data /work/policy.rego --input /work/input.json 'data.authz.allow')
[ "$actual" = true ] || {
  printf 'unexpected policy result: %s\n' "$actual" >&2
  exit 1
}

cat >"$tmp/invalid.rego" <<'EOF'
package authz

allow if {
EOF
if docker run --rm -v "$tmp:/work:ro" "$image" eval \
  --data /work/invalid.rego 'data.authz.allow' >/dev/null 2>&1; then
  printf '%s\n' 'invalid Rego unexpectedly succeeded' >&2
  exit 1
fi

printf '%s\n' '{"role":' >"$tmp/invalid.json"
if docker run --rm -v "$tmp:/work:ro" "$image" eval \
  --data /work/policy.rego --input /work/invalid.json \
  'data.authz.allow' >/dev/null 2>&1; then
  printf '%s\n' 'invalid input unexpectedly succeeded' >&2
  exit 1
fi

printf 'SMOKE PASS image=%s\n' "$image"
