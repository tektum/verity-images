#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# The repository registry image is the push and pull target.
registry_image='ghcr.io/tektum/registry@sha256:38539bc58065aa1634bde5ec90bf58963cc070ca26ae2ef72e286c3b37455fd7'
label=verity.test=crane-$$
network="verity-crane-network-$$"
registry="verity-crane-registry-$$"
work=$(mktemp -d)

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  docker logs "$registry" >&2 2>/dev/null || true
  printf '%s\n' "$1" >&2
  exit 1
}

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/crane"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'CA bundle environment is missing'

version=$(docker run --rm --network none --read-only "$image" version)
[ "$version" = "$expected_version" ] ||
  fail "crane version is '$version', expected '$expected_version'"

if docker run --rm --network none --read-only "$image" --definitely-invalid \
  >"$work/invalid" 2>&1; then
  fail 'invalid argument unexpectedly succeeded'
fi
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'invalid argument diagnostic is missing'

docker network create --label "$label" "$network" >/dev/null
docker run -d --label "$label" --name "$registry" --network "$network" \
  --network-alias registry "$registry_image" >/dev/null

crane() {
  docker run --rm --label "$label" --network "$network" --read-only \
    -v "$work:/work:ro" "$image" "$@"
}

attempts=0
until crane catalog --insecure registry:5000 >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || fail 'registry did not become ready for crane'
  sleep 1
done

mkdir -p "$work/layer"
printf 'verity crane smoke\n' >"$work/layer/hello.txt"
tar -C "$work/layer" -cf "$work/layer.tar" hello.txt
chmod -R a+rX "$work"

crane append --insecure -f /work/layer.tar -t registry:5000/smoke/hello:v1 \
  >"$work/pushed" 2>"$work/push.log" || {
  cat "$work/push.log" >&2
  fail 'crane append to the local registry failed'
}
grep -E '^registry:5000/smoke/hello@sha256:[0-9a-f]{64}$' "$work/pushed" >/dev/null ||
  fail 'crane append did not print the pushed digest reference'
pushed_digest=$(sed -n 's/^registry:5000\/smoke\/hello@//p' "$work/pushed")

crane manifest --insecure registry:5000/smoke/hello:v1 >"$work/manifest.json"
grep -F '"schemaVersion":2' "$work/manifest.json" >/dev/null ||
  fail 'manifest is missing schemaVersion 2'
grep -F '"layers":[' "$work/manifest.json" >/dev/null ||
  fail 'manifest is missing its layer list'

[ "$(crane digest --insecure registry:5000/smoke/hello:v1)" = "$pushed_digest" ] ||
  fail 'crane digest does not match the pushed digest'

crane copy --insecure registry:5000/smoke/hello:v1 registry:5000/smoke/hello:v2 \
  >/dev/null 2>"$work/copy.log" || {
  cat "$work/copy.log" >&2
  fail 'crane copy failed'
}
crane ls --insecure registry:5000/smoke/hello >"$work/tags"
grep -Fx v1 "$work/tags" >/dev/null || fail 'tag v1 is missing from crane ls'
grep -Fx v2 "$work/tags" >/dev/null || fail 'tag v2 is missing from crane ls'
[ "$(crane digest --insecure registry:5000/smoke/hello:v2)" = "$pushed_digest" ] ||
  fail 'copied tag does not resolve to the pushed digest'

crane export --insecure registry:5000/smoke/hello:v1 - >"$work/export.tar"
tar -xOf "$work/export.tar" hello.txt | grep -Fx 'verity crane smoke' >/dev/null ||
  fail 'exported filesystem is missing the pushed layer content'

if crane manifest --insecure registry:5000/smoke/hello:missing \
  >"$work/missing" 2>&1; then
  fail 'manifest for a missing tag unexpectedly succeeded'
fi
grep -F 'MANIFEST_UNKNOWN' "$work/missing" >/dev/null ||
  fail 'missing tag diagnostic is missing'

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$version"
